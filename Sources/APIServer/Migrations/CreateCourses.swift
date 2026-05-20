// APIServer/Migrations/CreateCourses.swift

import Fluent
import SQLKit

/// Canonical `courses` schema for net-new deploys.
///
/// Historically the schema was built up by:
///   - CreateCourses (this file)         — base columns + active-code partial unique index
///   - AddCourseOpenEnrollment           — `open_enrollment` Bool (later dropped)
///   - AddCourseEnrollmentMode           — drops `open_enrollment`, adds `enrollment_mode`
///   - AddCourseSections                 — creates the `course_sections` child table
///   - AddBrightSpaceSyncFields          — adds `brightspace_org_unit_id`
///
/// The consolidated form below produces the same final schema in a single
/// Create step.  Existing deploys have CreateCourses already marked
/// applied in `_fluent_migrations` and never re-run it, so the body
/// change is invisible to production.  The historical Add* migrations
/// remain registered and become no-ops on fresh deploys (they "run" but
/// the columns they would add already exist via this Create).
struct CreateCourses: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("courses")
            .id()
            .field("code", .string, .required)
            .field("name", .string, .required)
            .field("is_archived", .bool, .required)
            // Folded from AddCourseEnrollmentMode (which itself replaced the
            // boolean `open_enrollment` added by AddCourseOpenEnrollment).
            .field("enrollment_mode", .string, .required, .custom("DEFAULT 'open'"))
            // Folded from AddBrightSpaceSyncFields.
            .field("brightspace_org_unit_id", .string)
            .field("created_at", .datetime)
            .create()
        // Partial unique index: only one active course per code.
        // Archived courses are allowed to share a code (e.g. after term rollover import).
        if let sql = database as? SQLDatabase {
            let activePredicate =
                sql.dialect.name == "postgresql"
                ? "is_archived = FALSE"
                : "is_archived = 0"
            try await sql.raw(
                """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_courses_code_active
                ON courses(code)
                WHERE \(unsafeRaw: activePredicate)
                """
            ).run()
        }

        // Folded from AddCourseSections.  Created in the same Create* as its
        // parent table so the schema is coherent for fresh deploys; the
        // assignments table FK-references this via `section_id` (see
        // CreateAssignments).
        try await database.schema("course_sections")
            .id()
            .field("name", .string, .required)
            .field("default_grading_mode", .string, .required)
            .field("sort_order", .int, .required)
            .field(
                "course_id",
                .uuid,
                .required,
                .references("courses", "id", onDelete: .cascade)
            )
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("course_sections").delete()
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_courses_code_active").run()
        }
        try await database.schema("courses").delete()
    }
}
