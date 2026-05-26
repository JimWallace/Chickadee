// APIServer/Migrations/CreateBrightSpaceSyncLog.swift
//
// Append-only log of BrightSpace grade-push events (success / error /
// skipped).  Backs the BrightSpace tab's sync-activity view.  No foreign
// keys: the log snapshots identity fields and must outlive the records it
// describes, so a course/assignment/user delete never cascades into the
// audit trail.

import Fluent
import SQLKit

struct CreateBrightSpaceSyncLog: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("brightspace_sync_log")
            .id()
            .field("course_id", .uuid)
            .field("test_setup_id", .string, .required)
            .field("assignment_title", .string, .required)
            .field("user_id", .uuid)
            .field("username", .string, .required)
            .field("org_unit_id", .string)
            .field("grade_object_id", .string)
            .field("points", .double)
            .field("status", .string, .required)
            .field("detail", .string)
            .field("attempted_at", .datetime)
            .create()

        // Panel query is "most recent N events for this course" — index the
        // (course, time) access path so it stays cheap as the log grows.
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                """
                CREATE INDEX IF NOT EXISTS idx_bs_sync_log_course_time
                ON brightspace_sync_log(course_id, attempted_at)
                """
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_bs_sync_log_course_time").run()
        }
        try await database.schema("brightspace_sync_log").delete()
    }
}
