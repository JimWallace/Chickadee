// APIServer/Migrations/CreateCourses.swift

import Fluent
import SQLKit

struct CreateCourses: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("courses")
            .id()
            .field("code",        .string, .required)
            .field("name",        .string, .required)
            .field("is_archived", .bool,   .required)
            .field("created_at",  .datetime)
            .create()
        // Partial unique index: only one active course per code.
        // Archived courses are allowed to share a code (e.g. after term rollover import).
        if let sql = database as? SQLDatabase {
            try await sql.raw("""
                CREATE UNIQUE INDEX IF NOT EXISTS idx_courses_code_active
                ON courses(code)
                WHERE is_archived = 0
                """).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_courses_code_active").run()
        }
        try await database.schema("courses").delete()
    }
}
