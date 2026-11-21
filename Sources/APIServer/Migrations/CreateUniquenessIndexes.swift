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
// - `course_group_sets`: one set per course. Every lab feature reads the
//   course's first set (oldest, then by name), so a second set, made by two
//   creates at once, was read by nothing. The dedupe keeps that first set and
//   deletes the others with their groups, memberships and sessions (the
//   foreign keys cascade). Those groups were in no reader's set.
//
// Each step first removes the duplicates already present, keeping the newest
// row, so the unique index cannot fail on a production database. The older
// rows go on purpose: every reader already took the newest (credentials sort
// by `captured_at`, variants were meant to be one batch), so nothing reads
// them. An older duplicate tournament run is superseded, not deleted. The tables
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
        // then make the lookup index unique under the same name. One
        // transaction, so a variant the live server writes cannot land between
        // the dedupe and the build: it waits for the commit, and then meets
        // the unique index. The live server's validation logs that conflict
        // and keeps its primary run (`enqueueValidationVariants` is
        // best-effort); the next validation writes a whole batch.
        try await database.transaction { tx in
            guard let sql = tx as? (any SQLDatabase) else { return }
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
        try await uniqueGroupSetPerCourse(on: database)
    }

    /// One group set per course: keep the set the readers already take, the
    /// oldest (then by name, then by id), and index `course_id` as unique. One
    /// transaction, so a set the live server makes waits for the index.
    private func uniqueGroupSetPerCourse(on database: any Database) async throws {
        try await database.transaction { tx in
            guard let sql = tx as? (any SQLDatabase) else { return }
            try await sql.raw(
                """
                DELETE FROM course_group_sets WHERE id IN (
                  SELECT id FROM (
                    SELECT id, row_number() OVER (
                      PARTITION BY course_id ORDER BY created_at ASC NULLS FIRST, name, id) AS n
                    FROM course_group_sets
                  ) ranked WHERE n > 1)
                """
            ).run()
            try await sql.raw(
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_course_group_sets_course ON course_group_sets (course_id)"
            ).run()
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_course_group_sets_course").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_validation_variants_setup_index").run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_validation_variants_setup_index ON validation_variants(test_setup_id, variant_index)"
        ).run()
        try await sql.raw("DROP INDEX IF EXISTS idx_brightspace_credentials_user").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_tournament_runs_one_running").run()
    }
}
