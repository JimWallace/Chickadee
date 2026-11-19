// APIServer/Migrations/CreateUniquenessIndexes.swift
//
// Three "one row per X" rules that only app code held, now held by the
// database (docs/database-design.md, "Enforce uniqueness in the database").
// Each one was a read-then-write under READ COMMITTED, so two requests at
// once could both pass the read.
//
// - `tournament_runs`: one running run per setup and lab group. Starting a
//   tournament supersedes the running one, then inserts; two starts at once
//   could leave two running brackets, and a match job then advances both.
// - `brightspace_credentials`: one credential per scope (the deployment-wide
//   row has no user; each instructor has one). Saving deletes, then inserts;
//   two saves at once left two rows, and readers picked the newest.
// - `validation_variants`: one row per setup and variant index. A
//   re-validation replaces the batch; two overlapping ones could leave eight
//   rows, and the workbench listed both batches.
//
// Each step first removes the duplicates already present, keeping the newest
// row, so the unique index cannot fail on a production database. The tables
// are small (a row per tournament, per instructor, per variant), so the
// plain index builds are brief.
//
// `NULLS NOT DISTINCT` (Postgres 15+; production and CI run 16) makes the
// NULL group, and the NULL user, one scope rather than many.

import Fluent
import SQLKit

struct CreateUniquenessIndexes: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else { return }
        let running = APITournamentRun.Status.running
        let superseded = APITournamentRun.Status.superseded

        // Tournament runs: supersede every running run but the newest of its
        // setup and group.
        try await sql.raw(
            """
            UPDATE tournament_runs SET status = \(bind: superseded)
            WHERE status = \(bind: running) AND id IN (
              SELECT id FROM (
                SELECT id, row_number() OVER (
                  PARTITION BY test_setup_id, group_id ORDER BY started_at DESC, id DESC) AS n
                FROM tournament_runs WHERE status = \(bind: running)
              ) ranked WHERE n > 1)
            """
        ).run()
        try await sql.raw(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_tournament_runs_one_running \
            ON tournament_runs (test_setup_id, group_id) NULLS NOT DISTINCT \
            WHERE status = '\(unsafeRaw: running)'
            """
        ).run()

        // BrightSpace credentials: keep the newest row of each scope.
        try await sql.raw(
            """
            DELETE FROM brightspace_credentials WHERE id IN (
              SELECT id FROM (
                SELECT id, row_number() OVER (
                  PARTITION BY user_id ORDER BY captured_at DESC NULLS LAST, id DESC) AS n
                FROM brightspace_credentials
              ) ranked WHERE n > 1)
            """
        ).run()
        try await sql.raw(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_brightspace_credentials_user \
            ON brightspace_credentials (user_id) NULLS NOT DISTINCT
            """
        ).run()

        // Validation variants: keep the newest row of each setup and index,
        // then make the lookup index unique under the same name.
        try await sql.raw(
            """
            DELETE FROM validation_variants WHERE id IN (
              SELECT id FROM (
                SELECT id, row_number() OVER (
                  PARTITION BY test_setup_id, variant_index ORDER BY created_at DESC NULLS LAST, id DESC) AS n
                FROM validation_variants
              ) ranked WHERE n > 1)
            """
        ).run()
        try await sql.raw("DROP INDEX IF EXISTS idx_validation_variants_setup_index").run()
        try await sql.raw(
            """
            CREATE UNIQUE INDEX idx_validation_variants_setup_index \
            ON validation_variants (test_setup_id, variant_index)
            """
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_validation_variants_setup_index").run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_validation_variants_setup_index ON validation_variants(test_setup_id, variant_index)"
        ).run()
        try await sql.raw("DROP INDEX IF EXISTS idx_brightspace_credentials_user").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_tournament_runs_one_running").run()
    }
}
