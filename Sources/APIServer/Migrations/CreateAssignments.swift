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
//   - AddAssignmentStartsAt                    — `starts_at` (second round)
//   - AddAssignmentSecretRevealEnabled         — `secret_reveal_enabled` (second round)
//   - AddAssignmentBrightSpaceSyncExcluded     — `brightspace_sync_excluded` (second round)
//   - ChangeAssignmentIsOpenToVisibility       — dropped the original `is_open`
//     bool and added `visibility TEXT NOT NULL DEFAULT 'closed'` (second
//     round; this file now declares `visibility` directly and never creates
//     `is_open`, so a fresh deploy reaches the same end state without the
//     create-then-drop)
//
// Existing prod has the historical migrations already marked applied so the
// body changes are invisible to production; the folded Add*/Change* structs
// were deleted outright (Fluent ignores `_fluent_migrations` rows whose
// names are no longer registered).

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
            // Folded from ChangeAssignmentIsOpenToVisibility, which replaced
            // the original `is_open` bool with this three-state string
            // (AssignmentVisibility: "closed" | "preview" | "open").  Same
            // constraint and default as the ALTER it shipped as
            // (TEXT NOT NULL DEFAULT 'closed'); the default is harmless —
            // Fluent always writes the column.
            .field("visibility", .string, .required, .custom("DEFAULT 'closed'"))
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
            // Folded from AddAssignmentStartsAt: automatic open date.
            // nil = open as soon as published.
            .field("starts_at", .datetime)
            // Folded from AddAssignmentSecretRevealEnabled: per-assignment
            // secret-reveal-token toggle. nil/false = off.
            .field("secret_reveal_enabled", .bool)
            // Folded from AddAssignmentBrightSpaceSyncExcluded: explicit
            // "do not sync grades to LEARN" flag, distinct from unmapped.
            .field("brightspace_sync_excluded", .bool)
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
