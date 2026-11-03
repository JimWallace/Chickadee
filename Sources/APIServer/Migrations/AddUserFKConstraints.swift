// APIServer/Migrations/AddUserFKConstraints.swift
//
// Adds the two missing foreign-key constraints from `users.id`
// that were originally created as bare UUID columns (#562 audit):
//
//   submissions.retested_by_user_id  → users.id  ON DELETE SET NULL
//   class_achievements.user_id       → users.id  ON DELETE CASCADE
//
// Rationale (see docs/operational-diagnostics.md "User-row foreign-key cascade"
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
// `AdminRoutes.deleteUser` also cleans these rows up before it deletes the
// user row. That code dates from SQLite, which could not add these
// constraints to existing columns, and it agrees with them.

import Fluent
import SQLKit

struct AddUserFKConstraints: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else { return }

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

    func revert(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else { return }

        try? await sql.raw(
            "ALTER TABLE submissions DROP CONSTRAINT IF EXISTS fk_submissions_retested_by_user_id"
        ).run()
        try? await sql.raw(
            "ALTER TABLE class_achievements DROP CONSTRAINT IF EXISTS fk_class_achievements_user_id"
        ).run()
    }
}
