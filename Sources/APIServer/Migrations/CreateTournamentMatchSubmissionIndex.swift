import Fluent
import SQLKit

/// Index for the lookup every tournament match job makes twice: at claim
/// (`pairedOpponent`) and at result ingest (`recordTournamentMatch`), both
/// by `match_submission_id`. The table keeps every slot of every tournament
/// ever run, and its only index is the slot's identity
/// `(tournament_id, round, position)`, so each lookup was a full scan (#2278).
struct CreateTournamentMatchSubmissionIndex: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_tournament_matches_submission ON tournament_matches(match_submission_id)"
        ).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        try await sql.raw("DROP INDEX IF EXISTS idx_tournament_matches_submission").run()
    }
}
