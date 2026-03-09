// APIServer/Migrations/AddCourseToAssignments.swift
//
// Adds course_id to both test_setups and assignments. If there is existing
// data (users, test setups, or assignments), seeds a default course and
// migrates those rows and user enrollments into it. On a fresh database with
// no existing data the seeding step is skipped entirely.
//
// The default course code is read from the DEFAULT_COURSE_CODE environment
// variable (fallback: "DEFAULT"). Set DEFAULT_COURSE_NAME for the full name
// (fallback: "Default Course").

import Fluent
import SQLKit
import Foundation
import Vapor

struct AddCourseToAssignments: AsyncMigration {

    func prepare(on database: Database) async throws {
        // 1. Add course_id column to test_setups (nullable — set below).
        try await database.schema("test_setups")
            .field("course_id", .uuid)
            .update()

        // 2. Add course_id column to assignments (nullable — set below).
        try await database.schema("assignments")
            .field("course_id", .uuid)
            .update()

        // 3. Seed default course and migrate existing data via raw SQL,
        //    which is necessary for a data migration inside a schema migration.
        guard let sql = database as? SQLDatabase else {
            // Non-SQL backends (tests using in-memory stores) — skip seeding.
            return
        }

        // On a fresh database there is nothing to migrate, so skip seeding.
        // Check for any pre-existing rows across the three affected tables.
        struct CountRow: Decodable { let n: Int }
        let hasUsers      = try await sql.raw("SELECT COUNT(*) AS n FROM users").first(decoding: CountRow.self).map { $0.n > 0 } ?? false
        let hasSetups     = try await sql.raw("SELECT COUNT(*) AS n FROM test_setups").first(decoding: CountRow.self).map { $0.n > 0 } ?? false
        let hasAssignments = try await sql.raw("SELECT COUNT(*) AS n FROM assignments").first(decoding: CountRow.self).map { $0.n > 0 } ?? false

        guard hasUsers || hasSetups || hasAssignments else {
            // Fresh database — no existing data to migrate; first course will
            // be created by the admin through the normal UI.
            return
        }

        let courseCode = Environment.get("DEFAULT_COURSE_CODE")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "DEFAULT"
        let courseName = Environment.get("DEFAULT_COURSE_NAME")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "Default Course"

        let courseID = UUID()
        let courseIDStr = courseID.uuidString          // uppercase — must match Fluent's UUID storage convention
        let now = ISO8601DateFormatter().string(from: Date())

        // Insert default course.
        try await sql.raw("""
            INSERT INTO courses (id, code, name, is_archived, created_at)
            VALUES (\(literal: courseIDStr), \(literal: courseCode), \(literal: courseName), 0, \(literal: now))
            """).run()

        // Assign all existing test setups to the default course.
        try await sql.raw("""
            UPDATE test_setups SET course_id = \(literal: courseIDStr)
            WHERE course_id IS NULL
            """).run()

        // Assign all existing assignments to the default course.
        try await sql.raw("""
            UPDATE assignments SET course_id = \(literal: courseIDStr)
            WHERE course_id IS NULL
            """).run()

        // Enroll every existing user in the default course.
        struct UserIDRow: Decodable { let id: String }
        let users = try await sql.raw("SELECT id FROM users").all(decoding: UserIDRow.self)
        for user in users {
            let enrollmentID = UUID().uuidString          // uppercase — consistent with Fluent convention
            try await sql.raw("""
                INSERT OR IGNORE INTO course_enrollments (id, user_id, course_id, enrolled_at)
                VALUES (\(literal: enrollmentID), \(literal: user.id), \(literal: courseIDStr), \(literal: now))
                """).run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema("assignments")
            .deleteField("course_id")
            .update()
        try await database.schema("test_setups")
            .deleteField("course_id")
            .update()
        // Note: courses and course_enrollments are reverted by their own migrations.
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
