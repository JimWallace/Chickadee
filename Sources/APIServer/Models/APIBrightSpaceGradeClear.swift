// APIServer/Models/APIBrightSpaceGradeClear.swift
//
// A queued request to REMOVE a student's grade from BrightSpace for one test
// setup.  Enqueued when a (student, assignment) loses its only gradeable source
// — an instructor clears an override on a student with no submissions — AND
// Chickadee has previously pushed a grade for it (a `success` row exists in
// `brightspace_sync_log`).  That "we pushed it" gate is what keeps Chickadee
// from ever touching a grade an instructor entered by hand in LEARN.
//
// One row per (test_setup, user).  The grade-sync sweep processes pending rows
// with a D2L grade-value DELETE, then removes the row on success.  Carries the
// same four BrightSpace bookkeeping columns as results/overrides so the sweep's
// success / failure / retry paths treat it identically.

import Fluent
import Vapor

final class APIBrightSpaceGradeClear: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request/DB context.
    static let schema = "brightspace_grade_clears"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "test_setup_id")
    var testSetupID: String

    @Field(key: "user_id")
    var userID: UUID

    @OptionalField(key: "brightspace_sync_pending")
    var brightspaceSyncPending: Bool?

    @OptionalField(key: "brightspace_pending_since")
    var brightspacePendingSince: Date?

    @OptionalField(key: "brightspace_synced_at")
    var brightspaceSyncedAt: Date?

    @OptionalField(key: "brightspace_sync_error")
    var brightspaceSyncError: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(testSetupID: String, userID: UUID) {
        self.testSetupID = testSetupID
        self.userID = userID
        self.brightspaceSyncPending = true
    }
}
