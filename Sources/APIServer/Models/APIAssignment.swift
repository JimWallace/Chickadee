// APIServer/Models/APIAssignment.swift
//
// An assignment is a test setup that an instructor has published to the class.
// Students only see test setups that have a corresponding open assignment.
//
// Separating this from APITestSetup allows:
//   - Soft open/close without deleting the setup
//   - Due dates (isOpen flips to false automatically when due — future work)
//   - Per-student overrides later (another join table)

import Fluent
import Vapor

final class APIAssignment: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context.
    static let schema = "assignments"
    static let publicIDLength = 6

    @ID(key: .id)
    var id: UUID?

    /// Short public URL identifier (6-char base62 token).
    @Field(key: "public_id")
    var publicID: String

    /// Foreign reference to test_setups.id (string PK).
    @Field(key: "test_setup_id")
    var testSetupID: String

    /// Human-readable name shown in the student UI.
    @Field(key: "title")
    var title: String

    /// Optional deadline. nil = no deadline.
    @OptionalField(key: "due_at")
    var dueAt: Date?

    /// false = published but closed (students can no longer submit).
    @Field(key: "is_open")
    var isOpen: Bool

    /// Instructor-defined ordering for dashboard display (lower first).
    @OptionalField(key: "sort_order")
    var sortOrder: Int?

    /// Runner validation state for instructor-created assignments.
    /// Values: "pending" | "passed" | "failed"
    @OptionalField(key: "validation_status")
    var validationStatus: String?

    /// Submission ID for the runner validation run, if any.
    @OptionalField(key: "validation_submission_id")
    var validationSubmissionID: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    static func generatePublicID(length: Int = APIAssignment.publicIDLength) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
    }

    init(id: UUID? = nil, publicID: String = APIAssignment.generatePublicID(), testSetupID: String, title: String,
         dueAt: Date? = nil, isOpen: Bool = true,
         sortOrder: Int? = nil,
         validationStatus: String? = nil,
         validationSubmissionID: String? = nil) {
        self.id          = id
        self.publicID    = publicID
        self.testSetupID = testSetupID
        self.title       = title
        self.dueAt       = dueAt
        self.isOpen      = isOpen
        self.sortOrder   = sortOrder
        self.validationStatus = validationStatus
        self.validationSubmissionID = validationSubmissionID
    }
}
