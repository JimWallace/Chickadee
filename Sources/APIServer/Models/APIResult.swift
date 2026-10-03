// APIServer/Models/APIResult.swift

import Fluent
import Vapor

final class APIResult: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context,
    // never across unstructured concurrency.
    static let schema = "results"

    @ID(custom: "id", generatedBy: .user)
    var id: String?

    @Field(key: "submission_id")
    var submissionID: String

    // The serialised TestOutcomeCollection blob lives in the
    // `result_collections` side table (#1173) — see APIResultCollection.
    // Create result rows via `saveWithCollection(json:on:)` so the two rows
    // persist together; read the blob via `loadCollectionJSON(on:)`.

    /// "worker" (official, authoritative) or "browser" (student preview).
    /// Nil on rows created before this migration — treated as "worker".
    @OptionalField(key: "source")
    var source: String?

    // MARK: - Denormalized grade fields
    //
    // Copied out of `collection_json` at write time (and, historically,
    // backfilled by the grade-columns migration — since folded into
    // CreateResults) so list pages, the CSV export, and the periodic
    // sweeps can read a grade without decoding the full result blob per
    // row. `collection_json` stays the source of truth for everything else.

    @OptionalField(key: "earned_points")
    var earnedPoints: Double?

    @OptionalField(key: "total_points")
    var totalPoints: Double?

    @OptionalField(key: "pass_count")
    var passCount: Int?

    @OptionalField(key: "total_tests")
    var totalTests: Int?

    @Timestamp(key: "received_at", on: .create)
    var receivedAt: Date?

    // MARK: - BrightSpace grade sync fields

    /// True when this result is waiting to be pushed to BrightSpace (after debounce).
    @OptionalField(key: "brightspace_sync_pending")
    var brightspaceSyncPending: Bool?

    /// When the pending flag was set — used as the debounce anchor.
    @OptionalField(key: "brightspace_pending_since")
    var brightspacePendingSince: Date?

    /// When the grade was successfully pushed to BrightSpace.
    @OptionalField(key: "brightspace_synced_at")
    var brightspaceSyncedAt: Date?

    /// Last push error, if any (cleared on next successful push).
    @OptionalField(key: "brightspace_sync_error")
    var brightspaceSyncError: String?

    init() {}

    init(id: String, submissionID: String, source: String = "worker") {
        self.id = id
        self.submissionID = submissionID
        self.source = source
    }

    /// Stamps the denormalized grade columns from a serialized collection.
    /// Called by `saveWithCollection(json:on:)` so every creation path
    /// (worker report, browser report, bundle import) gets the columns
    /// without remembering to.
    func stampGradeFields(from collectionJSON: String) {
        guard let fields = CollectionGradeFields(json: collectionJSON) else { return }
        earnedPoints = fields.earnedPoints
        totalPoints = fields.totalPoints
        passCount = fields.passCount
        totalTests = fields.totalTests
    }
}

// MARK: - Column-first grade accessors
//
// The formulas are `CollectionGradeFields`'s, built from the denormalized
// columns, so they cannot drift from the blob readers in AssignmentHelpers.swift.
// Since #1173 the blob is not on this row, so there is no synchronous
// fallback: rows whose four columns are all nil report no grade — which
// matches the old fallback in every reachable state, because the historical
// grade-columns backfill covered every parseable blob and a blob it couldn't
// parse yielded nil from the fallback too. Loaders that must hydrate such rows
// anyway (gradeSummariesBySubmissionID's legacy path) fetch the blob from the
// side table explicitly.
extension APIResult {
    private var gradeFields: CollectionGradeFields {
        CollectionGradeFields(
            earnedPoints: earnedPoints, totalPoints: totalPoints,
            passCount: passCount, totalTests: totalTests)
    }

    /// Whole-result grade percent: weighted (earned/total) when totalPoints > 0,
    /// else unweighted pass/total test counts. Nil when neither is available.
    var gradePercentValue: Int? { gradeFields.gradePercent }

    /// Earned points (weighted when available, else pass count) for CSV/LEARN export.
    var gradePointsValue: Double? { gradeFields.gradePoints }

    /// Total possible weighted points; nil when the result predates weighted grading.
    var gradeTotalPointsValue: Double? { gradeFields.gradeTotalPoints }
}
