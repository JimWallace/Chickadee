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

    @ID(key: .id)
    var id: UUID?

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

    init(id: UUID? = nil, testSetupID: String, title: String,
         dueAt: Date? = nil, isOpen: Bool = true,
         validationStatus: String? = nil,
         validationSubmissionID: String? = nil) {
        self.id          = id
        self.testSetupID = testSetupID
        self.title       = title
        self.dueAt       = dueAt
        self.isOpen      = isOpen
        self.validationStatus = validationStatus
        self.validationSubmissionID = validationSubmissionID
    }
}
