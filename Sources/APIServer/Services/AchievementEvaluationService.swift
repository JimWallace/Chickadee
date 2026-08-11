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
    // Numerator guard (audit A7): only currently-enrolled per-course students
    // count toward `studentsMeeting` — staff test submissions and students who
    // dropped used to inflate it (the denominator already excludes them),
    // which could grant unearned bonus points all the way to the CSV/LMS.
    let studentIDsByCourse = try await studentUserIDsByCourse(courseIDs: goalCourseIDs, on: db)

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
        let enrolledStudents = studentIDsByCourse[assignment.courseID] ?? []
        let bestByStudent = try await bestAssignmentGradeByStudent(testSetupID: setupID, on: db)
            .filter { enrolledStudents.contains($0.key) }

        let outcome = try await writeClassGoalSnapshots(
            goals: goals,
            rowByAchievement: rowByAchievement,
            evaluation: ClassGoalEvaluation(
                setupID: setupID,
                bestByStudent: bestByStudent,
                denominator: denominator,
                locked: locked,
                now: now),
            on: db,
            logger: logger)
        written += outcome.written

        // The bonus a points-rewarded goal awards scales with live class
        // progress, so every grade already pushed to LEARN carries whatever
        // progress happened to be when THAT student's submission was graded.
        // Freezing at the deadline is the moment the final bonus exists — and
        // nothing else re-queues a push, because a push is only ever triggered
        // by a new result, an override, or the manual "Push all". Without this,
        // an assignment whose class goal completed late lands in LEARN with
        // every early submitter's bonus permanently under-counted.
        if outcome.bonusFroze {
            try await requeueFrozenClassGoalBonusPushes(
                assignment: assignment, testSetupID: setupID, on: db, logger: logger)
        }
    }

    if written > 0 {
        logger.debug("Class-goal achievement sweep wrote \(written) snapshot(s)")
    }
    return written
}

// MARK: - Snapshot writing

/// What one setup's snapshot write produced: how many rows were written, and
/// whether a **points-rewarded** goal crossed from live to frozen in this pass.
private struct ClassGoalWriteOutcome {
    var written: Int
    var bonusFroze: Bool
}

/// Everything one setup's goals are evaluated against in a single sweep pass:
/// which setup, the per-student grades over the enrolled roster, the roster
/// size, whether the deadline has passed, and the sweep's clock.
private struct ClassGoalEvaluation {
    let setupID: String
    let bestByStudent: [UUID: Double]
    let denominator: Int
    let locked: Bool
    let now: Date
}

/// Upserts one snapshot per evaluable goal on a setup and reports whether a
/// points-rewarded goal just froze — the transition that finalizes the bonus
/// every student's grade of record carries.
///
/// A goal that is *already* locked is skipped, so the freeze is reported exactly
/// once in an assignment's life: the sweep never re-opens a locked row (the
/// caller skips a setup whose goals are all locked), so a later due-date change
/// cannot re-trigger the re-push.
private func writeClassGoalSnapshots(
    goals: [Achievement],
    rowByAchievement: [String: APIAchievementResult],
    evaluation: ClassGoalEvaluation,
    on db: Database,
    logger: Logger
) async throws -> ClassGoalWriteOutcome {
    var outcome = ClassGoalWriteOutcome(written: 0, bonusFroze: false)
    let setupID = evaluation.setupID
    let denominator = evaluation.denominator
    let locked = evaluation.locked
    let now = evaluation.now

    for goal in goals {
        if rowByAchievement[goal.id]?.locked == true { continue }  // frozen at the deadline

        // Authoring rejects goal shapes the sweep can't evaluate (a single
        // "grade ≥ X" condition at most), but a hand-authored manifest can
        // still carry one — skip it loudly rather than silently mis-grade
        // the bonus as grade-only (audit A4).
        guard goal.isSweepEvaluableClassGoal else {
            logger.warning(
                """
                Class goal '\(goal.id)' on setup \(setupID) has conditions the sweep \
                cannot evaluate (only a single 'grade atLeast' condition is supported); skipping.
                """
            )
            continue
        }

        let threshold = goal.gradeThresholdFraction ?? 1
        let studentsMeeting = evaluation.bestByStudent.values.filter { $0 >= threshold }.count
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
        outcome.written += 1
        // A goal awarding no points moves no grade, so its freeze is not a
        // reason to re-push the class.
        if locked, (goal.reward.points ?? 0) > 0 { outcome.bonusFroze = true }
    }

    return outcome
}

// MARK: - Re-push at the freeze

/// Re-queues every student's grade for a setup whose class-goal bonus just
/// froze, so LEARN carries the final bonus rather than the value in effect when
/// each student's own submission happened to be graded.
///
/// Gated on the assignment actually being wired to a LEARN grade item (and not
/// explicitly excluded from sync), mirroring `flagResultForBrightSpaceSync`: on
/// a deployment with no BrightSpace binding this touches nothing. Runs at most
/// once per assignment, at the deadline, so it costs one push per student in
/// total — not the per-sweep churn that re-pushing on every progress *change*
/// would cost while the assignment is still live.
///
/// An assignment with no due date never freezes and so is never re-pushed here;
/// its bonus stays live-but-stale in LEARN, and "Push all" remains the way to
/// settle it.
private func requeueFrozenClassGoalBonusPushes(
    assignment: APIAssignment,
    testSetupID: String,
    on db: Database,
    logger: Logger
) async throws {
    guard assignment.brightspaceSyncExcluded != true,
        let gradeObjectID = assignment.brightspaceGradeObjectID,
        !gradeObjectID.isEmpty,
        let course = try await APICourse.find(assignment.courseID, on: db),
        let orgUnitID = course.brightspaceOrgUnitID,
        !orgUnitID.isEmpty
    else { return }

    let submissionIDs = try await APISubmission.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$kind == APISubmission.Kind.student)
        .all()
        .compactMap(\.id)
    guard !submissionIDs.isEmpty else { return }

    var results: [APIResult] = []
    for chunk in chunkedForInFilter(submissionIDs) {
        results += try await APIResult.query(on: db).filter(\.$submissionID ~~ chunk).all()
    }
    guard !results.isEmpty else { return }

    try await requeueForImmediateSync(results, on: db)
    logger.info(
        """
        Class-goal bonus froze for '\(assignment.title)' — re-queued \(results.count) \
        grade push(es) so LEARN carries the final bonus.
        """
    )
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
