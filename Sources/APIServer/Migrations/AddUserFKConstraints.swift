// APIServer/Migrations/AddUserFKConstraints.swift
//
// Adds the two missing foreign-key constraints from `api_users.id`
// that were originally created as bare UUID columns (#562 audit):
//
//   submissions.retested_by_user_id  → users.id  ON DELETE SET NULL
//   class_achievements.user_id       → users.id  ON DELETE CASCADE
//
// Rationale (see docs/operational-diagnostics.md "User-row FK cascade"
// table for the full enumeration):
//
//   * `submissions.retested_by_user_id` records "which instructor
//     pressed Retest." When that instructor is deleted, the submission
//     row must stay — it's an immutable grade-history record — but the
//     attribution drops. SET NULL is the right shape.
//
//   * `class_achievements.user_id` records "this student earned this
//     class-wide achievement on this submission." It is a denormalised
//     derived row keyed on the student; when the student is deleted
//     the derived row should go too. CASCADE.
//
// SQLite limitation: SQLite does NOT support `ALTER TABLE … ADD
// CONSTRAINT FOREIGN KEY` on an existing column. Recreating the table
// would require copying every row (submissions can be millions); the
// payoff is not worth that risk on dev/test SQLite installs. So this
// migration runs on Postgres only. On SQLite the same semantics are
// enforced by application code in `AdminRoutes.deleteUser`, which
// explicitly cleans these rows up before the user row is deleted.

import Fluent
import SQLKit

struct AddUserFKConstraints: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        guard sql.dialect.name == "postgresql" else {
            database.logger.info(
                "AddUserFKConstraints: skipping on \(sql.dialect.name) — SQLite cannot add FK constraints to existing columns; AdminRoutes.deleteUser enforces the same semantics in application code."
            )
            return
        }

        try await sql.raw(
            """
            ALTER TABLE class_achievements
            ADD CONSTRAINT fk_class_achievements_user_id
            FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
            """
        ).run()

        try await sql.raw(
            """
            ALTER TABLE submissions
            ADD CONSTRAINT fk_submissions_retested_by_user_id
            FOREIGN KEY (retested_by_user_id) REFERENCES users(id) ON DELETE SET NULL
            """
        ).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        guard sql.dialect.name == "postgresql" else { return }

        try? await sql.raw(
            "ALTER TABLE submissions DROP CONSTRAINT IF EXISTS fk_submissions_retested_by_user_id"
        ).run()
        try? await sql.raw(
            "ALTER TABLE class_achievements DROP CONSTRAINT IF EXISTS fk_class_achievements_user_id"
        ).run()
    }
}
