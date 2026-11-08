import Fluent
import SQLKit

/// Indexes for three lookups that scanned their whole table.
///
/// - `validation_variants` had no index. The instructor landing page reads the
///   variants of a set of setups, and every validation result looks up the
///   variant its submission graded.
/// - `audit_log` had no index on `actor_user_id` or `target_id`. The data
///   export filters on both, and `actor_user_id` is a foreign key to `users`
///   with `ON DELETE SET NULL`, so deleting a user scanned the whole log too.
/// - `class_achievements` is read by `submission_id` on every submission page;
///   its only index is the unique constraint on
///   `(test_setup_id, achievement_id)`.
struct CreateAuditAndValidationIndexes: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else { return }

        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_validation_variants_setup_index ON validation_variants(test_setup_id, variant_index)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_validation_variants_submission ON validation_variants(submission_id)"
        ).run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_audit_log_actor_user ON audit_log(actor_user_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_audit_log_target ON audit_log(target_id)").run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_class_achievements_submission ON class_achievements(submission_id)"
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else { return }

        try await sql.raw("DROP INDEX IF EXISTS idx_class_achievements_submission").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_audit_log_target").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_audit_log_actor_user").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_validation_variants_submission").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_validation_variants_setup_index").run()
    }
}
