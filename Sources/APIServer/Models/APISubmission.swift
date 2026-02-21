// APIServer/Models/APISubmission.swift

import Fluent
import Vapor

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

    @OptionalField(key: "attempt_number")
    var attemptNumber: Int?

    /// Non-nil when the submission is a raw file (not a zip).
    /// Stores the original filename so the worker can place it correctly.
    @OptionalField(key: "filename")
    var filename: String?

    /// The user who submitted (nil for submissions created before Phase 6).
    @OptionalField(key: "user_id")
    var userID: UUID?

    init() {}

    init(
        id: String,
        testSetupID: String,
        zipPath: String,
        attemptNumber: Int,
        status: String = "pending",
        filename: String? = nil,
        userID: UUID? = nil
    ) {
        self.id            = id
        self.testSetupID   = testSetupID
        self.zipPath       = zipPath
        self.attemptNumber = attemptNumber
        self.status        = status
        self.filename      = filename
        self.userID        = userID
    }
}
