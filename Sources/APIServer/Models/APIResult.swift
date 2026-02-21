// APIServer/Models/APIResult.swift

import Fluent
import Vapor

final class APIResult: Model, Content, @unchecked Sendable {
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

    init() {}

    init(id: String, submissionID: String, collectionJSON: String, source: String = "worker") {
        self.id             = id
        self.submissionID   = submissionID
        self.collectionJSON = collectionJSON
        self.source         = source
    }
}
