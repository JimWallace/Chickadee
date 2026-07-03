// APIServer/Services/AchievementEvaluationService.swift
//
// Periodic evaluation of class-wide (`classGoal`) achievements.  For each
// assignment whose manifest carries a class goal, the sweep computes how much
// of the class has reached the goal's threshold and upserts an
// `APIAchievementResult` snapshot per (setup, achievement).  The snapshot drives
// the student progress bar (Phase 3 display) and the positive grade bonus
// (Phase 3 grading).
//
// Periodic scaffolding (startup sweep + periodic timer, registered in
// `AppServices`) lives in `PeriodicSweepMonitor`; this file keeps the pure
// sweep functions plus the storage key and accessor.
//
// Individual achievement kinds (badges, records) are evaluated elsewhere and
// land in later phases; this sweep is class-aggregate only.

import Core
import Fluent
import Foundation
import Vapor

// 5 minutes: class-goal progress is a dashboard nicety, and each sweep walks
// every non-frozen goal-bearing assignment's submissions — at term scale a
// 60-second cadence spent most of its time re-running the same heavy scan
// (June 2026 audit, P1.2). Deadline locking still lands within one interval.
private let achievementSweepInterval: TimeInterval = 300

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

    // One batched query for every referenced setup instead of a find() per
    // assignment (June 2026 audit, P1.2 — this sweep runs on a timer forever).
    let setupIDs = Array(Set(assignments.map(\.testSetupID)))
    var setupByID: [String: APITestSetup] = [:]
    if !setupIDs.isEmpty {
        for setup in try await APITestSetup.query(on: db).filter(\.$id ~~ setupIDs).all() {
            if let id = setup.id { setupByID[id] = setup }
        }
    }

    // Pre-resolve which assignments actually carry class goals, so the
    // enrollment denominator is ONE scoped map for the whole sweep instead
    // of a per-assignment roster query (#1160 — many assignments share a
    // course, and this loop runs on a timer forever).
    let goalCarrying = assignments.compactMap { assignment -> (APIAssignment, APITestSetup, [Achievement])? in
        guard let setup = setupByID[assignment.testSetupID],
            let props = try? JSONDecoder().decode(TestProperties.self, from: Data(setup.manifest.utf8))
        else { return nil }
        let goals = props.achievements.filter { $0.isClassGoal }
        guard !goals.isEmpty else { return nil }
        return (assignment, setup, goals)
    }
    guard !goalCarrying.isEmpty else { return 0 }

    let goalCourseIDs = Array(Set(goalCarrying.map { $0.0.courseID }))
    let countsByCourse = try await enrolledStudentCountsByCourse(courseIDs: goalCourseIDs, on: db)

    for (assignment, setup, goals) in goalCarrying {
        guard let setupID = setup.id else { continue }

        let existing = try await APIAchievementResult.query(on: db)
            .filter(\.$testSetupID == setupID)
            .all()
        var rowByAchievement: [String: APIAchievementResult] = [:]
        for row in existing { rowByAchievement[row.achievementID] = row }

        // Every goal here already frozen → nothing to recompute for this setup.
        if goals.allSatisfy({ rowByAchievement[$0.id]?.locked == true }) { continue }

        let denominator = countsByCourse[assignment.courseID] ?? 0
        let locked = assignment.dueAt.map { $0 <= now } ?? false
        let bestByStudent = try await bestAssignmentGradeByStudent(testSetupID: setupID, on: db)

        for goal in goals {
            if rowByAchievement[goal.id]?.locked == true { continue }  // frozen at the deadline

            let threshold = goal.gradeThresholdFraction ?? 1
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
    // Blob-free (#1160): the fold only reads gradePercentValue.
    let preferred = try await preferredGradeSummariesBySubmissionID(for: identified.map(\.id), on: db)

    var best: [UUID: Double] = [:]
    for sub in identified {
        guard let result = preferred[sub.id],
            let percent = result.gradePercentValue
        else { continue }
        let value = Double(percent) / 100
        if value > (best[sub.userID] ?? -1) { best[sub.userID] = value }
    }
    return best
}

// MARK: - Monitor storage (scaffolding in PeriodicSweepMonitor)

struct AchievementEvaluationMonitorKey: StorageKey {
    typealias Value = PeriodicSweepMonitor
}

extension Application {
    var achievementEvaluationMonitor: PeriodicSweepMonitor {
        get {
            if let existing = storage[AchievementEvaluationMonitorKey.self] { return existing }
            let created = PeriodicSweepMonitor(
                name: "Class-goal achievement",
                interval: achievementSweepInterval,
                minimumInterval: 1,
                runImmediately: true
            ) { application in
                _ = try await evaluateClassGoalAchievements(
                    on: application.db, logger: application.logger)
            }
            storage[AchievementEvaluationMonitorKey.self] = created
            return created
        }
        set { storage[AchievementEvaluationMonitorKey.self] = newValue }
    }
}
