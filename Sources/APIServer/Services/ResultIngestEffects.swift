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

    /// A graded collection, ready to store as a new result row: the row,
    /// already marked for the two grade-sync channels (BrightSpace and LTI),
    /// and the encoded collection. The caller saves it with
    /// `row.saveWithCollection(json:on:)`.
    struct PreparedResult {
        let row: APIResult
        let json: String
    }

    /// Encodes `collection`, builds its result row and marks the row for grade
    /// sync, on `db`.
    ///
    /// `encodedJSON`, when given, must be the encoding of exactly `collection`
    /// by the stored-collection encoder (`.iso8601` dates, default formatting),
    /// as `TestOutcomeCollection.boundedForStorage` returns it. It saves
    /// encoding the collection a second time. Nil encodes it here.
    ///
    /// Both ingest paths call this (#2259, item 5). The browser copy once
    /// skipped the grade-sync flag, so notebook labs never reached LEARN on
    /// their own. Each caller saves the row inside its own transaction or
    /// retry, because the two differ for a reason: the worker report completes
    /// its submission in the same transaction, and the browser path has just
    /// created its submission row. On the worker path the flag rides inside
    /// that transaction: a result the sweeps never see never reaches the LMS.
    static func prepareResult(
        _ collection: TestOutcomeCollection,
        source: String,
        testSetupID: String,
        encodedJSON: Data? = nil,
        application: Application,
        on db: any Database
    ) async throws -> PreparedResult {
        let data: Data
        if let encodedJSON {
            data = encodedJSON
        } else {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(collection)
        }
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let row = APIResult(
            id: freshShortID(prefix: "res"), submissionID: collection.submissionID, source: source)
        try await requestGradePush(.result(row, application: application), testSetupID: testSetupID, on: db)
        return PreparedResult(row: row, json: json)
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

    /// Runs one side effect and logs anything it throws.
    ///
    /// None of these may fail the request. The grade is already stored when
    /// they run, so a throw turns a submission that graded perfectly into a
    /// failed report: the browser shows "Failed to submit results" while the
    /// row sits in the database (the `grading-probe` intermittent,
    /// docs/ci-flakiness.md), and a runner retries a report the server already
    /// holds.
    ///
    /// A class badge is worth an ordinary amount; a student's grade is not
    /// worth losing for one.
    ///
    /// Returns whether `work` succeeded, for an effect that has a way to make
    /// up for a failure (the leaderboard's repair).
    @discardableResult
    func bestEffort(_ what: String, submissionID: String, _ work: () async throws -> Void) async -> Bool {
        do {
            try await work()
            return true
        } catch {
            logger.warning("result_side_effect_failed \(what) for \(submissionID): \(error)")
            return false
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
    /// the activity match, the class-composite contribution, and the class
    /// records a 100% earns. Never throws.
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

        // Class composite: the student's part of the shared image, and the
        // slot's coverage row when it passed (docs/class-composite.md).
        // It reads the setup only for a composite outcome, so it runs ahead
        // of the shared read below and does not depend on it.
        await bestEffort("composite_contribution", submissionID: submissionID) {
            try await CompositeContributions.record(submission: submission, collection: collection, on: db)
        }

        // Every effect below reads the same setup row, manifest included.
        // Read once here: each helper used to find it again, five reads of
        // the row per report.
        let setup: APITestSetup
        do {
            guard let found = try await APITestSetup.find(testSetupID, on: db) else { return }
            setup = found
        } catch {
            logger.warning("result_side_effect_failed setup_read for \(submissionID): \(error)")
            return
        }

        // Only contribution assignments accumulate a union, so the slot count
        // comes from the instructor's starter notebook, read through
        // `notebookBytesCache` (#1171). No notebook is 0 slots: "not a
        // contribution assignment", the right answer for every ordinary one.
        let slotCount = await declaredContributionSlotCount(setup: setup, app: application)
        await bestEffort("class_item_coverage", submissionID: submissionID) {
            try await recordClassItemCoverage(
                setup: setup, userID: userID, submissionID: submissionID,
                outcomes: collection.outcomes, declaredSlotCount: slotCount, on: db)
            // A new contribution changes what the class's combined corpus
            // covers, so the corpus is re-graded: the class's, or the lab's
            // on an activity that runs per lab group. Debounced to one run
            // in flight per assignment, or per lab.
            if slotCount > 0 {
                await scheduleClassCorpusRun(
                    afterSubmission: submissionID, userID: userID, setupID: testSetupID, app: application, on: db,
                    logger: logger)
            }
        }

        // A ranking metric is whatever the script measured, and the script
        // decides whether a failing run reports one, so this is outside the
        // 100% gate too.
        //
        // A failed write is not left lost: it schedules a repair of the
        // assignment's board from the stored results
        // (`LeaderboardRepairQueue`), on the application's database because
        // it runs after this request has finished.
        let ranked = await bestEffort("leaderboard_entry", submissionID: submissionID) {
            try await recordLeaderboardEntry(
                setup: setup, userID: userID, submissionID: submissionID,
                outcomes: collection.outcomes, reachedAt: Date(), on: db)
        }
        if !ranked {
            let appDB = application.db
            await application.leaderboardRepairQueue.schedule(testSetupID, logger: logger) {
                try await repairLeaderboardEntries(testSetupID: testSetupID, on: appDB)
            }
        }

        // King of the hill and the round robin: complete the match this job
        // played (docs/class-activities.md).
        await bestEffort("activity_match", submissionID: submissionID) {
            try await recordActivityMatch(
                setup: setup, userID: userID, submissionID: submissionID,
                outcomes: collection.outcomes, matches: matches, on: db)
        }

        guard !isRetest, gradePercent(from: collection) == 100 else { return }
        let disabled = BuiltInAchievements.disabled(in: setup)
        await bestEffort("class_badges", submissionID: submissionID) {
            try await awardClassBadgesFor100Percent(
                setup: setup, userID: userID, submissionID: submissionID,
                executionTimeMs: collection.executionTimeMs,
                attemptNumber: submission.attemptNumber ?? 1,
                disabled: disabled, on: db)
        }
    }
}
