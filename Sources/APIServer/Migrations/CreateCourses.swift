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
///   - AddBrightSpaceOrgUnitName         — `brightspace_org_unit_name` (second round)
///   - AddCourseBrightSpaceSyncUserID    — `brightspace_sync_user_id` (second round)
///   - AddCourseBrightSpaceSectionCategoryID — `brightspace_section_category_id` (second round)
///   - AddCourseMCPInstructions          — `mcp_instructions` (second round)
///   - AddCourseArchivedAt               — `archived_at` (second round; its backfill
///     stamped already-archived courses and is a no-op on an empty fresh table)
///   - AddCourseSlipDaySettings          — the three slip-day policy columns
///     (third round, #1252)
///   - AddCourseSlipDayRevealHold        — `slip_day_release_reveal_hold`
///   - AddLTILaunchColumns               — `lti_platform_id`, `lti_context_id`
///   - AddLTIGradeColumns                — `lti_line_items_url`, `lti_grades_enabled`
///   - AddLTIMembershipsColumn           — `lti_memberships_url`
///   - AddCourseTerm                     — `term_year`, `term_season`
///   - ScopeCourseCodeIndexToTerm        — the active-code index scoped to the
///     term (all six in the fourth round, #1806)
///
/// The consolidated form below produces the same final schema in a single
/// Create step.  Existing deploys have CreateCourses already marked
/// applied in `_fluent_migrations` and never re-run it, so the body
/// change is invisible to production; the folded Add* structs were
/// deleted outright (Fluent ignores `_fluent_migrations` rows whose
/// names are no longer registered).
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
            // Folded from AddBrightSpaceOrgUnitName: the human-readable D2L
            // org-unit name, cached at bind time. nil = not bound / unverified.
            .field("brightspace_org_unit_name", .string)
            // Folded from AddCourseBrightSpaceSyncUserID: the instructor whose
            // connected LEARN identity drives grade sync (NULL = deployment-wide
            // identity). Bare uuid (no FK), matching the org-unit columns.
            .field("brightspace_sync_user_id", .uuid)
            // Folded from AddCourseBrightSpaceSectionCategoryID: the D2L group
            // category whose groups map to sections. nil = not configured.
            .field("brightspace_section_category_id", .string)
            // Folded from AddCourseMCPInstructions: per-course authoring
            // guidance for MCP agents. nil = inherit the house guide.
            .field("mcp_instructions", .string)
            // Folded from AddCourseArchivedAt: when the course was archived —
            // the retention clock's zero point. nil = not archived.
            .field("archived_at", .datetime)
            // Folded from AddCourseSlipDaySettings (#1228): the course-level
            // slip-day policy. All nullable; nil reads as "never configured",
            // which `SlipDayPolicy.resolve` treats as disabled.
            .field("slip_days_enabled", .bool)
            .field("slip_days_per_student", .int)
            .field("slip_day_extension_hours", .int)
            // Folded from AddCourseSlipDayRevealHold: the course-level opt-out
            // for the release-output slip-day reveal hold. nil = hold on.
            .field("slip_day_release_reveal_hold", .bool)
            // Folded from AddLTILaunchColumns, AddLTIGradeColumns and
            // AddLTIMembershipsColumn (docs/lti-1-3.md): the platform binding,
            // the AGS line-items URL and transport choice, and the NRPS
            // memberships URL. `lti_platform_id` is a bare uuid with no FK.
            .field("lti_platform_id", .uuid)
            .field("lti_context_id", .string)
            .field("lti_line_items_url", .string)
            .field("lti_grades_enabled", .bool)
            .field("lti_memberships_url", .string)
            // Folded from AddCourseTerm (docs/course-terms.md): the year and
            // term of the offering. nil = no term recorded.
            .field("term_year", .int)
            .field("term_season", .string)
            .field("created_at", .datetime)
            .create()
        // Partial unique index: one active course per code and term. Archived
        // courses may share a code (e.g. after a term rollover import).
        // Folded from ScopeCourseCodeIndexToTerm. The term columns are wrapped
        // in COALESCE because SQL treats two NULLs as distinct: without it, two
        // courses that record no term could share a code.
        if let sql = database as? SQLDatabase {
            let activePredicate =
                sql.dialect.name == "postgresql"
                ? "is_archived = FALSE"
                : "is_archived = 0"
            try await sql.raw(
                """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_courses_code_term_active
                ON courses(code, COALESCE(term_year, 0), COALESCE(term_season, ''))
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
            try await sql.raw("DROP INDEX IF EXISTS idx_courses_code_term_active").run()
        }
        try await database.schema("courses").delete()
    }
}
