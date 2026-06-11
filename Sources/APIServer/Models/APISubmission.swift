// APIServer/Models/APISubmission.swift

import Fluent
import Vapor

/// Lifecycle states for a submission row.
///
/// The `status` DB column stays a plain string (no migration); this enum is
/// the authoritative vocabulary for it.  `running` is included because the
/// diagnostics queries and the MCP validation watcher both recognize it as a
/// live state, even though the server itself currently writes only the other
/// four.
enum SubmissionStatus: String, Sendable {
    case pending
    case assigned
    case running
    case complete
    case failed
}

final class APISubmission: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context,
    // never across unstructured concurrency.
    static let schema = "submissions"

    enum Kind {
        static let student = "student"
        static let validation = "validation"
    }

    @ID(custom: "id", generatedBy: .user)
    var id: String?

    @Field(key: "test_setup_id")
    var testSetupID: String

    @Field(key: "status")
    var status: String  // SubmissionStatus raw value; column stays a string

    @OptionalField(key: "worker_id")
    var workerID: String?

    @Field(key: "zip_path")
    var zipPath: String

    @Timestamp(key: "submitted_at", on: .create)
    var submittedAt: Date?

    @OptionalField(key: "assigned_at")
    var assignedAt: Date?

    /// Set when an instructor triggers a re-test. Used in place of `submittedAt`
    /// when computing queue-wait and turnaround statistics for re-test runs.
    @OptionalField(key: "retested_at")
    var retestedAt: Date?

    /// The instructor who triggered the most recent retest, or nil for the
    /// original student submission.  Nil for auto-retests fired by the
    /// assignment-revise path when the initiating user could not be
    /// determined (should not happen in practice — the Save button is
    /// gated by `RoleMiddleware`).
    @OptionalField(key: "retested_by_user_id")
    var retestedByUserID: UUID?

    @OptionalField(key: "attempt_number")
    var attemptNumber: Int?

    /// Non-nil when the submission is a raw file (not a zip).
    /// Stores the original filename so the worker can place it correctly.
    @OptionalField(key: "filename")
    var filename: String?

    /// The user who submitted (nil for submissions created before Phase 6).
    @OptionalField(key: "user_id")
    var userID: UUID?

    /// Distinguishes learner submissions from instructor validation runs.
    @Field(key: "kind")
    var kind: String

    /// Cached per-student personalization for a validation submission, resolved
    /// once at enqueue (`materializeValidationGrading`) so the worker poll +
    /// download paths stay eval-free. JSON-encoded `SubmissionMaterialization`;
    /// nil for student submissions, non-personalized assignments, and pre-fix rows.
    @OptionalField(key: "materialization_json")
    var materializationJSON: String?

    init() {}

    init(
        id: String,
        testSetupID: String,
        zipPath: String,
        attemptNumber: Int,
        status: String = SubmissionStatus.pending.rawValue,
        filename: String? = nil,
        userID: UUID? = nil,
        kind: String = Kind.student
    ) {
        self.id = id
        self.testSetupID = testSetupID
        self.zipPath = zipPath
        self.attemptNumber = attemptNumber
        self.status = status
        self.filename = filename
        self.userID = userID
        self.kind = kind
    }
}

// MARK: - Typed status accessors

extension APISubmission {
    /// The submission's status as a typed enum, or nil if the stored string
    /// is outside the known vocabulary (defensive — should not happen).
    var statusValue: SubmissionStatus? { SubmissionStatus(rawValue: status) }

    /// Sets the status from the typed enum.  Prefer this over assigning a
    /// raw string to `status`.
    func setStatus(_ newStatus: SubmissionStatus) {
        status = newStatus.rawValue
    }
}
