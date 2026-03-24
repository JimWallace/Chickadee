// APIServer/Migrations/AddCourseEnrollmentMode.swift
//
// Replaces the boolean open_enrollment column with a three-state enrollment_mode
// string column ('open' | 'auto' | 'closed').
//
// Data migration: courses that had open_enrollment = 0 become 'closed'.
// All others (open_enrollment = 1, the default) become 'open'.
// No existing courses become 'auto'; that mode must be set explicitly.

import Fluent
import SQLKit

struct AddCourseEnrollmentMode: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("courses")
            .field("enrollment_mode", .string, .required, .custom("DEFAULT 'open'"))
            .update()

        // Data migration: courses that were closed get the 'closed' mode.
        try await (database as! SQLDatabase)
            .raw("UPDATE courses SET enrollment_mode = 'closed' WHERE open_enrollment = 0")
            .run()

        try await database.schema("courses")
            .deleteField("open_enrollment")
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("courses")
            .field("open_enrollment", .bool, .required, .custom("DEFAULT TRUE"))
            .update()

        try await (database as! SQLDatabase)
            .raw("UPDATE courses SET open_enrollment = CASE WHEN enrollment_mode = 'closed' THEN 0 ELSE 1 END")
            .run()

        try await database.schema("courses")
            .deleteField("enrollment_mode")
            .update()
    }
}
