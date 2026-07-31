// APIServer/Migrations/CreateSlipDaySpends.swift
//
// The slip-day ledger (#1228): one row per spent slip day.  Deliberately NO
// unique constraint on (user, assignment) — days stack, so a second day on
// the same assignment is a second row.  Refunds stamp `refunded_at` rather
// than deleting, keeping the ledger a complete history.  Cascade-deletes
// follow the parent user / course / assignment; `refunded_by_user_id` is
// only attribution, so it nulls out if the staff account is deleted.

import Fluent
import SQLKit

struct CreateSlipDaySpends: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("slip_day_spends")
            .id()
            .field(
                "user_id",
                .uuid,
                .required,
                .references("users", "id", onDelete: .cascade)
            )
            .field(
                "course_id",
                .uuid,
                .required,
                .references("courses", "id", onDelete: .cascade)
            )
            .field(
                "assignment_id",
                .uuid,
                .required,
                .references("assignments", "id", onDelete: .cascade)
            )
            .field("extension_due_at", .datetime, .required)
            .field("spent_at", .datetime)
            .field("refunded_at", .datetime)
            .field(
                "refunded_by_user_id",
                .uuid,
                .references("users", "id", onDelete: .setNull)
            )
            .create()

        if let sql = database as? SQLDatabase {
            // Balance checks filter on (user, course); the roster ledger scans
            // by course.
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_slip_day_spends_user_course ON slip_day_spends(user_id, course_id)"
            ).run()
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_slip_day_spends_course ON slip_day_spends(course_id)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_slip_day_spends_user_course").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_slip_day_spends_course").run()
        }
        try await database.schema("slip_day_spends").delete()
    }
}
