// APIServer/Migrations/AddBrightSpaceSyncFields.swift
//
// Adds BrightSpace grade-sync fields to courses, assignments, users, and results.
//
//   courses.brightspace_org_unit_id  — D2L org unit ID for this course
//   assignments.brightspace_grade_object_id — D2L grade item ID for this assignment
//   users.brightspace_user_id        — D2L internal user ID (cached after first lookup)
//   results.brightspace_sync_pending — flag: grade push is waiting for debounce
//   results.brightspace_pending_since — when the pending flag was set (debounce anchor)
//   results.brightspace_synced_at    — when the grade was successfully pushed
//   results.brightspace_sync_error   — last error message if push failed

import Fluent

struct AddBrightSpaceSyncFields: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("courses")
            .field("brightspace_org_unit_id", .string)
            .update()

        try await database.schema("assignments")
            .field("brightspace_grade_object_id", .string)
            .update()

        try await database.schema("users")
            .field("brightspace_user_id", .string)
            .update()

        try await database.schema("results")
            .field("brightspace_sync_pending", .bool)
            .field("brightspace_pending_since", .datetime)
            .field("brightspace_synced_at", .datetime)
            .field("brightspace_sync_error", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("courses")
            .deleteField("brightspace_org_unit_id")
            .update()

        try await database.schema("assignments")
            .deleteField("brightspace_grade_object_id")
            .update()

        try await database.schema("users")
            .deleteField("brightspace_user_id")
            .update()

        try await database.schema("results")
            .deleteField("brightspace_sync_pending")
            .deleteField("brightspace_pending_since")
            .deleteField("brightspace_synced_at")
            .deleteField("brightspace_sync_error")
            .update()
    }
}
