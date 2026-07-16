// APIServer/Models/APIGradeOverride.swift
//
// Per-student grade override on a test setup.  An override replaces the
// runner-assigned best grade for one student on one assignment, both in the
// instructor's per-student submissions view and in the BrightSpace grade
// sync (see `bestGradeForStudent` in BrightSpaceGradeSyncService).  The
// stored value is a whole-number percent (0–100); BrightSpace works in
// points, so the sync converts it against the suite's total possible points
// and rescales onto the grade item's own max.
//
// One row per (test_setup, user) — enforced by the composite UNIQUE index in
// CreateGradeOverrides.

import Fluent
import Vapor

final class APIGradeOverride: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context.
    static let schema = "grade_overrides"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "test_setup_id")
    var testSetupID: String

    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "override_percent")
    var overridePercent: Int

    @OptionalField(key: "note")
    var note: String?

    @OptionalField(key: "granted_by_user_id")
    var grantedByUserID: UUID?

    @Timestamp(key: "granted_at", on: .create)
    var grantedAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    // BrightSpace grade-sync bookkeeping, mirroring the columns on APIResult.
    // Only set when the override is the *only* thing to push — i.e. the student
    // has no submissions, so there's no result row to carry the pending flag
    // (see `applyGradeOverride` / `sweepBrightSpaceGradeSync`).
    @OptionalField(key: "brightspace_sync_pending")
    var brightspaceSyncPending: Bool?

    @OptionalField(key: "brightspace_pending_since")
    var brightspacePendingSince: Date?

    @OptionalField(key: "brightspace_synced_at")
    var brightspaceSyncedAt: Date?

    @OptionalField(key: "brightspace_sync_error")
    var brightspaceSyncError: String?

    init() {}

    init(
        id: UUID? = nil,
        testSetupID: String,
        userID: UUID,
        overridePercent: Int,
        note: String? = nil,
        grantedByUserID: UUID? = nil
    ) {
        self.id = id
        self.testSetupID = testSetupID
        self.userID = userID
        self.overridePercent = overridePercent
        self.note = note
        self.grantedByUserID = grantedByUserID
    }
}
