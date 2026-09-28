// APIServer/Models/APILTIGradeSync.swift
//
// One student's AGS push state for one test setup (docs/lti-1-3.md "Grades
// through AGS"). A change that can move the grade sets `pending`; the AGS
// sweep sends the student's current best grade and clears it. The row holds
// no grade: the sweep computes it when it sends, so a queued push never sends
// a stale value.

import Fluent
import Vapor

final class APILTIGradeSync: Model, @unchecked Sendable {
    // @unchecked Sendable: only mutated within a request/DB context before save.
    static let schema = "lti_grade_syncs"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "test_setup_id")
    var testSetupID: String

    @Field(key: "pending")
    var pending: Bool

    /// When the row became pending. The sweep waits out the debounce window
    /// from this time, so a burst of submissions sends one score.
    @OptionalField(key: "pending_since")
    var pendingSince: Date?

    /// When the LMS last accepted a score for this row. Nil = never, so there
    /// is nothing on the LMS to clear.
    @OptionalField(key: "synced_at")
    var syncedAt: Date?

    /// Why the last push failed. Nil after a success.
    @OptionalField(key: "error")
    var error: String?

    init() {}

    init(userID: UUID, testSetupID: String, pendingSince: Date) {
        self.userID = userID
        self.testSetupID = testSetupID
        self.pending = true
        self.pendingSince = pendingSince
    }
}
