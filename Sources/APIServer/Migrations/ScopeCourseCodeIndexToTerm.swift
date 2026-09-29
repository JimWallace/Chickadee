// APIServer/Migrations/ScopeCourseCodeIndexToTerm.swift
//
// Course codes become unique per term (docs/course-terms.md slice 3): two
// active offerings may share a code when their terms differ. This replaces
// the partial unique index on `courses(code)` with one on the code and the
// term, still over non-archived rows only.
//
// The term columns are wrapped in COALESCE on purpose. SQL treats two NULLs
// as distinct, so without it two courses that record no term could share a
// code — exactly what the old index forbade. With it, "no term" is one value
// and the pre-term rule holds for every course that has not declared one.
// SQLite and Postgres both accept expression indexes with a WHERE clause.
//
// Fold into CreateCourses in the next consolidation round once every
// deployment has verifiably applied it.

import Fluent
import SQLKit

struct ScopeCourseCodeIndexToTerm: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_courses_code_active").run()
        try await sql.raw(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_courses_code_term_active
            ON courses(code, COALESCE(term_year, 0), COALESCE(term_season, ''))
            WHERE \(unsafeRaw: Self.activePredicate(sql))
            """
        ).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_courses_code_term_active").run()
        try await sql.raw(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_courses_code_active
            ON courses(code)
            WHERE \(unsafeRaw: Self.activePredicate(sql))
            """
        ).run()
    }

    /// The same non-archived predicate `CreateCourses` uses.
    private static func activePredicate(_ sql: SQLDatabase) -> String {
        sql.dialect.name == "postgresql" ? "is_archived = FALSE" : "is_archived = 0"
    }
}
