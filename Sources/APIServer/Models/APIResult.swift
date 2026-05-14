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
    }
}
