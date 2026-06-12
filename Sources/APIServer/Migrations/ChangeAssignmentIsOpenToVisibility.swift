// APIServer/Migrations/ChangeAssignmentIsOpenToVisibility.swift
//
// Replaces the boolean `is_open` column on `assignments` with a three-state
// `visibility` string column (AssignmentVisibility: "closed" | "preview" |
// "open").
//
// Shipped standalone (not folded into CreateAssignments) because production
// databases already applied CreateAssignments with `is_open` and would never
// pick up a body change. Fresh deploys run CreateAssignments (which still
// creates `is_open`) and then this migration converts it; existing prod runs
// only this one.  The backfill maps true -> "open", false -> "closed"; it never
// produces "preview", which only arises from later authoring transitions.

import Fluent
import SQLKit

struct ChangeAssignmentIsOpenToVisibility: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        // Add NOT NULL with a default so existing rows are valid immediately
        // (and the non-optional model field never sees a NULL); the backfill
        // below replaces the placeholder with the real per-row value. The
        // default is harmless thereafter — Fluent always writes the column.
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "ALTER TABLE assignments ADD COLUMN visibility TEXT NOT NULL DEFAULT 'closed'"
            ).run()
            try await sql.raw(
                "UPDATE assignments SET visibility = CASE WHEN is_open THEN 'open' ELSE 'closed' END"
            ).run()
        } else {
            // Non-SQL drivers (none in practice): best-effort nullable add.
            try await database.schema("assignments").field("visibility", .string).update()
        }
        try await database.schema("assignments")
            .deleteField("is_open")
            .update()
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "ALTER TABLE assignments ADD COLUMN is_open BOOLEAN NOT NULL DEFAULT false"
            ).run()
            try await sql.raw(
                "UPDATE assignments SET is_open = CASE WHEN visibility = 'open' THEN true ELSE false END"
            ).run()
        } else {
            try await database.schema("assignments").field("is_open", .bool).update()
        }
        try await database.schema("assignments")
            .deleteField("visibility")
            .update()
    }
}
