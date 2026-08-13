import Fluent
import SQLKit

/// Covering index for the worker claim query's fresh-work-first split.
///
/// `collectClaimCandidates` asks for pending student work in two passes —
/// `retested_at IS NULL` first, then the retests — so a manifest-revision sweep
/// cannot starve students who are actively submitting (#427). The pre-existing
/// `idx_submissions_status_kind_submitted_at` stops at `submitted_at`, so the
/// `retested_at` predicate was left to a filter step: when the queue is
/// retest-dominated (exactly what #427 exists to handle) the planner had to walk
/// the whole pending range to prove that fewer than 50 fresh rows existed, on
/// every poll from every runner slot.
///
/// Column order matches the query: the two equality predicates, then the
/// nullability split, then the sort key (#1361).
struct CreateClaimPriorityIndex: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_submissions_claim_priority ON submissions(status, kind, retested_at, submitted_at)"
        ).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        try await sql.raw("DROP INDEX IF EXISTS idx_submissions_claim_priority").run()
    }
}
