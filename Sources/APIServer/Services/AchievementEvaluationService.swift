// APIServer/Services/AchievementEvaluationService.swift
//
// Periodic evaluation of class-wide (`classGoal`) achievements.  For each
// assignment whose manifest carries a class goal, the sweep computes how much
// of the class has reached the goal's threshold and upserts an
// `APIAchievementResult` snapshot per (setup, achievement).  The snapshot drives
// the student progress bar (Phase 3 display) and the positive grade bonus
// (Phase 3 grading).
//
// Modeled on `StuckSubmissionReaperService` / `AssignmentDeadlineService`:
// a pure sweep function + a Task-based monitor + a LifecycleHandler (startup
// sweep + periodic timer) registered in `AppServices`.
//
// Individual achievement kinds (badges, records) are evaluated elsewhere and
// land in later phases; this sweep is class-aggregate only.

import Core
import Fluent
import Foundation
import Vapor

private let achievementSweepInterval: TimeInterval = 60

/// Fraction of a class goal reached, `0...1`: the share of the roster meeting
/// the threshold, scaled by the goal's target share.  Returns `1.0` once
/// `classFraction` of the class (or more) has reached it, and `0` for an empty
/// roster.  Pure — unit-tested without a database.
func classGoalProgress(studentsMeeting: Int, denominator: Int, classFraction: Double) -> Double {
    guard denominator > 0 else { return 0 }
    let reached = Double(studentsMeeting) / Double(denominator)
    let target = max(classFraction, 0.0001)
    return min(1, reached / target)
}

/// Evaluates every assignment's `classGoal` achievements and upserts one
/// `APIAchievementResult` snapshot per (setup, achievement).  A snapshot whose
/// assignment deadline has passed is locked and then frozen — later sweeps skip
/// it.  Returns the number of snapshots written.
@discardableResult
func evaluateClassGoalAchievements(
    on db: Database,
    logger: Logger,
    now: Date = Date()
) async throws -> Int {
    let assignments = try await APIAssignment.query(on: db).all()
    var written = 0

    for assignment in assignments {
        guard let setup = try await APITestSetup.find(assignment.testSetupID, on: db),
            let setupID = setup.id,
            let props = try? JSONDecoder().decode(TestProperties.self, from: Data(setup.manifest.utf8))
        else { continue }

        let goals = props.achievements.filter { $0.kind == .classGoal }
        guard !goals.isEmpty else { continue }

        let existing = try await APIAchievementResult.query(on: db)
            .filter(\.$testSetupID == setupID)
            .all()
        var rowByAchievement: [String: APIAchievementResult] = [:]
        for row in existing { rowByAchievement[row.achievementID] = row }

        // Every goal here already frozen → nothing to recompute for this setup.
        if goals.allSatisfy({ rowByAchievement[$0.id]?.locked == true }) { continue }

        let denominator = try await enrolledStudentCount(forCourse: assignment.courseID, on: db)
        let locked = assignment.dueAt.map { $0 <= now } ?? false
        let bestByStudent = try await bestAssignmentGradeByStudent(testSetupID: setupID, on: db)

        for goal in goals {
            if rowByAchievement[goal.id]?.locked == true { continue }  // frozen at the deadline

            let threshold = goal.threshold ?? 1
            let studentsMeeting = bestByStudent.values.filter { $0 >= threshold }.count
            let progress = classGoalProgress(
                studentsMeeting: studentsMeeting,
                denominator: denominator,
                classFraction: goal.classFraction ?? 1)

            if let row = rowByAchievement[goal.id] {
                row.studentsMeeting = studentsMeeting
                row.denominator = denominator
                row.progress = progress
                row.locked = locked
                row.evaluatedAt = now
                try await row.save(on: db)
            } else {
                try await APIAchievementResult(
                    testSetupID: setupID,
                    achievementID: goal.id,
                    studentsMeeting: studentsMeeting,
                    denominator: denominator,
                    progress: progress,
                    locked: locked,
                    evaluatedAt: now
                ).save(on: db)
            }
            written += 1
        }
    }

    if written > 0 {
        logger.debug("Class-goal achievement sweep wrote \(written) snapshot(s)")
    }
    return written
}

/// Per-student best whole-assignment grade (`0...1`) for a setup, from
/// worker-authoritative results (browser previews lose to a worker result).
///
/// `classGoal` currently grades on the whole-assignment metric; per-item /
/// per-section targets are a follow-up (there is no way to author one until the
/// Phase 5 editor, so this covers every goal that can exist today).
func bestAssignmentGradeByStudent(testSetupID: String, on db: Database) async throws -> [UUID: Double] {
    let submissions = try await APISubmission.query(on: db)
        .filter(\.$kind == APISubmission.Kind.student)
        .filter(\.$testSetupID == testSetupID)
        .all()
    let identified = submissions.compactMap { sub -> (id: String, userID: UUID)? in
        guard let id = sub.id, let userID = sub.userID else { return nil }
        return (id, userID)
    }
    let preferred = try await preferredResultsBySubmissionID(for: identified.map(\.id), on: db)

    var best: [UUID: Double] = [:]
    for sub in identified {
        guard let result = preferred[sub.id],
            let percent = gradePercentFromCollectionJSON(result.collectionJSON)
        else { continue }
        let value = Double(percent) / 100
        if value > (best[sub.userID] ?? -1) { best[sub.userID] = value }
    }
    return best
}

// MARK: - Monitor + lifecycle (same shape as StuckSubmissionReaperMonitor)

final class AchievementEvaluationMonitor: @unchecked Sendable {
    // @unchecked Sendable: `task` is touched only from start()/stop() on the
    // app lifecycle (didBoot/shutdown), never concurrently.
    private var task: Task<Void, Never>?
    private let intervalNanoseconds: UInt64

    init(interval: TimeInterval = achievementSweepInterval) {
        intervalNanoseconds = UInt64(max(interval, 1) * 1_000_000_000)
    }

    func start(application: Application) {
        guard task == nil else { return }
        task = Task {
            while !Task.isCancelled {
                do {
                    _ = try await evaluateClassGoalAchievements(
                        on: application.db, logger: application.logger)
                } catch {
                    application.logger.error(
                        "Class-goal achievement sweep failed: \(error.localizedDescription)")
                }
                do { try await Task.sleep(nanoseconds: intervalNanoseconds) } catch { break }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

struct AchievementEvaluationMonitorKey: StorageKey {
    typealias Value = AchievementEvaluationMonitor
}

struct AchievementEvaluationLifecycleHandler: LifecycleHandler {
    func didBoot(_ application: Application) throws {
        Task {
            do {
                _ = try await evaluateClassGoalAchievements(
                    on: application.db, logger: application.logger)
            } catch {
                application.logger.error(
                    "Initial class-goal achievement sweep failed: \(error.localizedDescription)")
            }
        }
        application.achievementEvaluationMonitor.start(application: application)
    }

    func shutdown(_ application: Application) {
        application.achievementEvaluationMonitor.stop()
    }
}

extension Application {
    var achievementEvaluationMonitor: AchievementEvaluationMonitor {
        get {
            if let existing = storage[AchievementEvaluationMonitorKey.self] { return existing }
            let created = AchievementEvaluationMonitor()
            storage[AchievementEvaluationMonitorKey.self] = created
            return created
        }
        set { storage[AchievementEvaluationMonitorKey.self] = newValue }
    }
}
