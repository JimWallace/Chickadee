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

    @Field(key: "collection_json")
    var collectionJSON: String  // serialised TestOutcomeCollection

    /// "worker" (official, authoritative) or "browser" (student preview).
    /// Nil on rows created before this migration — treated as "worker".
    @OptionalField(key: "source")
    var source: String?

    // MARK: - Denormalized grade fields
    //
    // Copied out of `collection_json` at write time (and backfilled by
    // `AddResultGradeColumns`) so list pages, the CSV export, and the
    // periodic sweeps can read a grade without decoding the full result
    // blob per row. `collection_json` stays the source of truth for
    // everything else.

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

    init(id: String, submissionID: String, collectionJSON: String, source: String = "worker") {
        self.id = id
        self.submissionID = submissionID
        self.collectionJSON = collectionJSON
        self.source = source
        populateGradeFields()
    }

    /// Stamps the denormalized grade columns from `collectionJSON`. Called by
    /// the designated initializer so every creation path (worker report,
    /// browser report, bundle import) gets the columns without remembering to.
    func populateGradeFields() {
        guard let data = collectionJSON.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        earnedPoints = (root["earnedPoints"] as? Double) ?? (root["earnedPoints"] as? Int).map(Double.init)
        totalPoints = (root["totalPoints"] as? Double) ?? (root["totalPoints"] as? Int).map(Double.init)
        passCount = root["passCount"] as? Int
        totalTests = root["totalTests"] as? Int
    }
}

// MARK: - Column-first grade accessors
//
// Same semantics as gradePercentFromCollectionJSON / gradePointsFromCollectionJSON
// / gradeTotalPointsFromCollectionJSON in AssignmentHelpers.swift, but reading
// the denormalized columns. Rows that predate the columns (all four nil — e.g.
// written mid-deploy before AddResultGradeColumns ran) fall back to parsing the
// blob, so the two paths can never disagree.
extension APIResult {
    private var hasGradeColumns: Bool {
        earnedPoints != nil || totalPoints != nil || passCount != nil || totalTests != nil
    }

    /// Whole-result grade percent: weighted (earned/total) when totalPoints > 0,
    /// else unweighted pass/total test counts. Nil when neither is available.
    var gradePercentValue: Int? {
        guard hasGradeColumns else { return gradePercentFromCollectionJSON(collectionJSON) }
        if let earned = earnedPoints, let total = totalPoints, total > 0 {
            return Int((earned / total * 100).rounded())
        }
        guard let pass = passCount, let total = totalTests, total > 0 else { return nil }
        return Int((Double(pass) / Double(total) * 100).rounded())
    }

    /// Earned points (weighted when available, else pass count) for CSV/LEARN export.
    var gradePointsValue: Double? {
        guard hasGradeColumns else { return gradePointsFromCollectionJSON(collectionJSON) }
        if let total = totalPoints, total > 0, let earned = earnedPoints { return earned }
        return passCount.map(Double.init)
    }

    /// Total possible weighted points; nil when the result predates weighted grading.
    var gradeTotalPointsValue: Double? {
        guard hasGradeColumns else { return gradeTotalPointsFromCollectionJSON(collectionJSON) }
        if let total = totalPoints, total > 0 { return total }
        return nil
    }
}
