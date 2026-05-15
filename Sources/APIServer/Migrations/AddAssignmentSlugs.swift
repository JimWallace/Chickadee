// APIServer/Migrations/AddAssignmentSlugs.swift
//
// CONSOLIDATED.  The `slug` column, the (course_id, slug) unique index,
// and the original backfill loop are folded into CreateAssignments as of
// v0.4.171.  This migration's struct name remains in `app.migrations`
// (see DatabaseConfiguration.registerMigrations) so existing production
// deploys, which already have it marked applied in `_fluent_migrations`,
// see no change.  On a fresh deploy the no-op runs and does nothing
// because CreateAssignments already produced the column and index.

import Fluent

struct AddAssignmentSlugs: AsyncMigration {
    func prepare(on database: Database) async throws {
        // No-op: see CreateAssignments.swift for the canonical schema.
    }

    func revert(on database: Database) async throws {
        // No-op.  CreateAssignments' revert tears down the column.
    }
}
