// APIServer/Migrations/AddEnrollmentSlipDaysAdjustment.swift
//
// Per-student slip-day budget adjustment on `course_enrollments` (#1228):
// staff hand one student extra days (or claw them back) without touching the
// course-wide policy.  Nullable; nil reads as 0.  Balance = course budget +
// adjustment − unrefunded spends.

import Fluent

struct AddEnrollmentSlipDaysAdjustment: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("course_enrollments")
            .field("slip_days_adjustment", .int)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("course_enrollments")
            .deleteField("slip_days_adjustment")
            .update()
    }
}
