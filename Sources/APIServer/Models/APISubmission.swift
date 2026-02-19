// APIServer/Models/APISubmission.swift

import Fluent
import Vapor

// @unchecked Sendable: Fluent's Model property wrappers are not Sendable.
// Access is always through async Fluent/Vapor contexts which ensure safety.
final class APISubmission: Model, Content, @unchecked Sendable {
    static let schema = "submissions"

    @ID(custom: "id", generatedBy: .user)
    var id: String?

    @Field(key: "test_setup_id")
    var testSetupID: String

    @Field(key: "status")
    var status: String          // pending | assigned | complete | failed

    @OptionalField(key: "worker_id")
    var workerID: String?

    @Field(key: "zip_path")
    var zipPath: String

    @Timestamp(key: "submitted_at", on: .create)
    var submittedAt: Date?

    @OptionalField(key: "assigned_at")
    var assignedAt: Date?

    init() {}

    init(
        id: String,
        testSetupID: String,
        zipPath: String,
        status: String = "pending"
    ) {
        self.id          = id
        self.testSetupID = testSetupID
        self.zipPath     = zipPath
        self.status      = status
    }
}
