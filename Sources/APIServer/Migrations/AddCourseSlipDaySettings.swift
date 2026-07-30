// APIServer/Migrations/AddCourseSlipDaySettings.swift
//
// Course-level slip-day policy (#1228): whether students may spend self-serve
// deadline extensions, how many each student gets per term, and how many
// hours one day buys.  All three are nullable so pre-existing courses decode
// as "never configured" — `SlipDayPolicy.resolve` treats that as disabled
// with the 2 × 24 h defaults pre-filled for when the feature is switched on.
//
// One column per ALTER — SQLite can't add multiple columns in one statement,
// the same constraint that shapes AddEnrollmentBrightSpaceSyncStatus.

import Fluent

struct AddCourseSlipDaySettings: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("courses")
            .field("slip_days_enabled", .bool)
            .update()
        try await database.schema("courses")
            .field("slip_days_per_student", .int)
            .update()
        try await database.schema("courses")
            .field("slip_day_extension_hours", .int)
            .update()
    }

    func revert(on database: Database) async throws {
        // One DROP COLUMN per ALTER, mirroring the adds.
        try await database.schema("courses")
            .deleteField("slip_days_enabled")
            .update()
        try await database.schema("courses")
            .deleteField("slip_days_per_student")
            .update()
        try await database.schema("courses")
            .deleteField("slip_day_extension_hours")
            .update()
    }
}
