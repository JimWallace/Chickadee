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

    @Timestamp(key: "received_at", on: .create)
    var receivedAt: Date?

    init() {}

    init(id: String, submissionID: String, collectionJSON: String) {
        self.id             = id
        self.submissionID   = submissionID
        self.collectionJSON = collectionJSON
    }
}
