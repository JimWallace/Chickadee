// APIServer/Migrations/RequireAssignmentSlug.swift
//
// `assignments.slug` becomes NOT NULL, as `APIAssignment.slug` (a non-optional
// `String`) already assumes. The column arrived nullable with the folded
// `AddAssignmentSlugs`, so a row with no slug would fail to decode on every
// page that reads its course. `ModelSchemaAgreementTests` found the
// disagreement.
//
// Any row still without a slug gets one from its public ID first. The
// `(course_id, slug)` index is unique, and public IDs are unique, so the
// backfill cannot collide. Every server version writes a slug, so the
// constraint is safe while a blue and a green server share the database.

import Fluent
import SQLKit

struct RequireAssignmentSlug: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(
            "UPDATE assignments SET slug = 'assignment-' || public_id WHERE slug IS NULL"
        ).run()
        try await sql.raw("ALTER TABLE assignments ALTER COLUMN slug SET NOT NULL").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE assignments ALTER COLUMN slug DROP NOT NULL").run()
    }
}
