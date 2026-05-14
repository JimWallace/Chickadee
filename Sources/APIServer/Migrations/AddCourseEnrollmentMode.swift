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
        let sql = database as! SQLDatabase
        let closedPredicate =
            sql.dialect.name == "postgresql"
            ? "open_enrollment = FALSE"
            : "open_enrollment = 0"
        try await sql
            .raw("UPDATE courses SET enrollment_mode = 'closed' WHERE \(unsafeRaw: closedPredicate)")
            .run()

        try await database.schema("courses")
            .deleteField("open_enrollment")
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("courses")
            .field("open_enrollment", .bool, .required, .custom("DEFAULT TRUE"))
            .update()

        let sql = database as! SQLDatabase
        let falseLiteral = sql.dialect.name == "postgresql" ? "FALSE" : "0"
        let trueLiteral = sql.dialect.name == "postgresql" ? "TRUE" : "1"
        try await sql
            .raw(
                "UPDATE courses SET open_enrollment = CASE WHEN enrollment_mode = 'closed' THEN \(unsafeRaw: falseLiteral) ELSE \(unsafeRaw: trueLiteral) END"
            )
            .run()

        try await database.schema("courses")
            .deleteField("enrollment_mode")
            .update()
    }
}
