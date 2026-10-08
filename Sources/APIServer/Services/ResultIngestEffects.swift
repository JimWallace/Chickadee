// APIServer/Services/ResultIngestEffects.swift
//
// Everything a stored result triggers besides the grade, for every ingest path
// (#1708). The worker report (`ResultRoutes`) and the browser result
// (`BrowserResultRoutes`) used to wire these by hand, and they had already
// drifted: the browser copy retried and logged each effect, the worker copy
// threw, and only the worker copy passed the round-robin match reports on. A
// side effect wired at only one path silently reports half the class as the
// whole of it, and a side effect that throws on one path turns a stored grade
// into a failed report. One service, called by both, closes both.
//
// The grade-sync flags and the validation verdict live here too, because both
// ingest paths need them and they were spelled twice.

import Core
import Fluent
import Foundation
import Vapor

struct ResultIngestEffects {
    let application: Application
    let db: any Database
    let logger: Logger

    // MARK: - With the result save

    /// Marks a result for the two grade-sync channels, BrightSpace and LTI.
    /// Runs with the result save, inside its transaction where there is one:
    /// a result the sweeps never see never reaches the LMS.
    static func flagForGradeSync(
        _ result: APIResult, testSetupID: String, application: Application, on db: any Database
    ) async throws {
        try await flagResultForBrightSpaceSync(
            result, testSetupID: testSetupID, application: application, on: db)
        try await LTIGradeSyncQueue.queue(submissionID: result.submissionID, testSetupID: testSetupID, on: db)
    }

    /// Records a validation run's verdict on the assignment it validates, or
    /// on the per-variant row it belongs to, so the instructor sees pass or
    /// fail without polling. The two lookups are disjoint: a variant run is
    /// never the assignment's linked primary.
    func recordValidationVerdict(_ collection: TestOutcomeCollection) async throws {
        let passed =
            collection.buildStatus == .passed
            && collection.totalTests > 0
            && collection.failCount == 0
            && collection.errorCount == 0
            && collection.timeoutCount == 0
        let status = passed ? "passed" : "failed"

        if let assignment = try await APIAssignment.query(on: db)
            .filter(\.$validationSubmissionID == collection.submissionID)
            .first()
        {
            assignment.validationStatus = status
            try await assignment.save(on: db)
            logger.info(
                "Validation \(status) for assignment '\(assignment.title)' (submission \(collection.submissionID))")
        }

        if let variant = try await ValidationVariant.query(on: db)
            .filter(\.$submissionID == collection.submissionID)
            .first()
        {
            variant.status = status
            try await variant.save(on: db)
            logger.info("Validation variant \(variant.variantIndex) \(status) for setup \(variant.testSetupID)")
        }
    }

    // MARK: - After the result save: best effort

    /// Runs one side effect, retrying the transient database race and logging
    /// anything that survives the retries.
    ///
    /// None of these may fail the request. The grade is already stored when
    /// they run, so a throw turns a submission that graded perfectly into a
    /// failed report: the browser shows "Failed to submit results" while the
    /// row sits in the database (the `grading-probe` intermittent,
    /// docs/ci-flakiness.md), and a runner retries a report the server already
    /// holds.
    ///
    /// Why they throw at all, when SQLite is meant to wait: sqlite-nio's busy
    /// handler retries forever, so ordinary contention never surfaces. What it
    /// cannot cover is `SQLITE_BUSY_SNAPSHOT`, a WAL read snapshot gone stale
    /// because another connection committed in between, which SQLite returns
    /// at once because waiting cannot help. Only starting again can, which is
    /// what `withTransientDatabaseLockRetry` does. Every effect here is
    /// read-then-write, the exact shape that hits it.
    ///
    /// A class badge is worth an ordinary amount; a student's grade is not
    /// worth losing for one.
    func bestEffort(_ what: String, submissionID: String, _ work: () async throws -> Void) async {
        do {
            try await withTransientDatabaseLockRetry(on: db) { try await work() }
        } catch {
            logger.warning("result_side_effect_failed \(what) for \(submissionID): \(error)")
        }
    }

    /// First-to-submit records (Pathfinder), at the moment a student's
    /// submission row exists. The worker path creates the row at upload, the
    /// browser path when the result arrives, so each caller decides when;
    /// this decides how. Never throws.
    func awardFirstToSubmit(setup: APITestSetup, userID: UUID, submissionID: String) async {
        await bestEffort("first_to_submit", submissionID: submissionID) {
            try await awardFirstToSubmitRecords(
                setup: setup, userID: userID, submissionID: submissionID, on: db)
        }
    }

    /// The class-level effects of one student's result: the union of covered
    /// items (and the corpus re-run it schedules), the activity leaderboard,
    /// the activity match, and the class records a 100% earns. Never throws.
    ///
    /// Two gates, kept visible: coverage, the leaderboard and the match are
    /// per item or per run and need only a build that passed; the records are
    /// per student and need 100%. Only a student's own submission counts, so
    /// a validation run, a tournament match or a corpus run reaches none of
    /// this.
    ///
    /// A retest result is the exception for the records: it recomputes them
    /// from every submission's latest result, whatever this result's grade or
    /// build, because a worse retest result must be able to take a record away
    /// (#2054, A12). `recomputeClassRecords` explains the rule.
    func apply(submission: APISubmission, collection: TestOutcomeCollection, matches: [MatchReport]? = nil) async {
        guard submission.kind == APISubmission.Kind.student,
            let userID = submission.userID,
            let submissionID = submission.id
        else { return }
        let testSetupID = submission.testSetupID
        let isRetest = submission.retestedAt != nil
        if isRetest {
            await application.classRecordRecomputeQueue.run(testSetupID) {
                await bestEffort("class_record_recompute", submissionID: submissionID) {
                    guard let setup = try await APITestSetup.find(testSetupID, on: db) else { return }
                    try await recomputeClassRecords(setup: setup, on: db)
                }
            }
        }
        guard collection.buildStatus == .passed else { return }

        // Only contribution assignments accumulate a union, so the slot count
        // comes from the instructor's starter notebook, read through
        // `notebookBytesCache` (#1171). No notebook is 0 slots: "not a
        // contribution assignment", the right answer for every ordinary one.
        let slotCount = await declaredContributionSlotCount(testSetupID: testSetupID, app: application, on: db)
        await bestEffort("class_item_coverage", submissionID: submissionID) {
            try await recordClassItemCoverage(
                testSetupID: testSetupID, userID: userID, submissionID: submissionID,
                outcomes: collection.outcomes, declaredSlotCount: slotCount, on: db)
            // A new contribution changes what the class's combined corpus
            // covers, so the corpus is re-graded. Debounced to one run in
            // flight per assignment.
            if slotCount > 0 {
                await scheduleClassCorpusRun(setupID: testSetupID, app: application, on: db, logger: logger)
            }
        }

        // A ranking metric is whatever the script measured, and the script
        // decides whether a failing run reports one, so this is outside the
        // 100% gate too.
        await bestEffort("leaderboard_entry", submissionID: submissionID) {
            try await recordLeaderboardEntry(
                testSetupID: testSetupID, userID: userID, submissionID: submissionID,
                outcomes: collection.outcomes, on: db)
        }

        // King of the hill and the round robin: complete the match this job
        // played (docs/class-activities.md).
        await bestEffort("activity_match", submissionID: submissionID) {
            try await recordActivityMatch(
                testSetupID: testSetupID, userID: userID, submissionID: submissionID,
                outcomes: collection.outcomes, matches: matches, on: db)
        }

        guard !isRetest, gradePercent(from: collection) == 100 else { return }
        let disabled =
            (try? await APITestSetup.find(testSetupID, on: db))
            .map { BuiltInAchievements.disabled(in: $0) } ?? []
        await bestEffort("class_badges", submissionID: submissionID) {
            try await awardClassBadgesFor100Percent(
                testSetupID: testSetupID, userID: userID, submissionID: submissionID,
                executionTimeMs: collection.executionTimeMs,
                attemptNumber: submission.attemptNumber ?? 1,
                disabled: disabled, on: db)
        }
    }
}
