// APIServer/Migrations/CreateAssignments.swift
//
// An "assignment" is a test setup that an instructor has published to students.
// Students only see test setups that have a corresponding open assignment.
//
// Canonical schema for net-new deploys.  Historically built up by:
//   - CreateAssignments (this file)            — base columns + unique indexes
//   - AddAssignmentSlugs                       — `slug` + unique (course_id, slug)
//   - AddCourseSections                        — `section_id` FK to course_sections
//   - AddAssignmentDeadlineOverrideActive      — `deadline_override_active`
//   - AddBrightSpaceSyncFields                 — `brightspace_grade_object_id`
//
// The historical Add* migrations remain registered and become no-ops on
// fresh deploys; existing prod has them already marked applied so the
// body changes are invisible to production.

import Fluent
import SQLKit

struct CreateAssignments: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("assignments")
            .id()
            .field("public_id", .string, .required)
            .field(
                "test_setup_id",
                .string,
                .required,
                .references("test_setups", "id", onDelete: .cascade)
            )
            .field("title", .string, .required)
            .field("due_at", .datetime)
            .field("is_open", .bool, .required)
            .field("validation_status", .string)
            .field(
                "validation_submission_id",
                .string,
                .references("submissions", "id", onDelete: .setNull)
            )
            .field("sort_order", .int)
            .field(
                "course_id",
                .uuid,
                .required,
                .references("courses", "id", onDelete: .cascade)
            )
            // Folded from AddAssignmentSlugs.  Unique index (course_id, slug)
            // created below after the table.
            .field("slug", .string)
            // Folded from AddCourseSections.  Nullable for ungrouped assignments;
            // ON DELETE SET NULL so removing a section leaves orphaned
            // assignments in the trailing Ungrouped bucket.
            .field(
                "section_id",
                .uuid,
                .references("course_sections", "id", onDelete: .setNull)
            )
            // Folded from AddAssignmentDeadlineOverrideActive.
            .field("deadline_override_active", .bool)
            // Folded from AddBrightSpaceSyncFields.
            .field("brightspace_grade_object_id", .string)
            .field("created_at", .datetime)
            .unique(on: "public_id")
            .unique(on: "test_setup_id")
            .create()

        // Folded from AddAssignmentSlugs.  The historical migration ran a
        // backfill loop over existing rows before creating the index; on a
        // fresh deploy there are no rows yet, so the index can be created
        // immediately.
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE UNIQUE INDEX idx_assignments_course_slug ON assignments (course_id, slug)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_assignments_course_slug").run()
        }
        try await database.schema("assignments").delete()
    }
}
