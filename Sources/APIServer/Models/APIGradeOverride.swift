// APIServer/Models/APIGradeOverride.swift
//
// Per-student grade override on a test setup.  An override replaces the
// runner-assigned best grade for one student on one assignment, both in the
// instructor's per-student submissions view and in the BrightSpace grade
// sync (see `bestPointsForStudent` in BrightSpaceGradeSyncService).  The
// stored value is a whole-number percent (0–100); BrightSpace works in
// points, so the sync converts it against the suite's total possible points.
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
