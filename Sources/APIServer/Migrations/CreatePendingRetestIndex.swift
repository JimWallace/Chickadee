import Fluent
import SQLKit

/// Index for the retest pass of the claim walk: pending student work that
/// carries a `retested_at`, oldest `submitted_at` first
/// (`ClaimCandidateLoader`).
///
/// Every older index that returns those rows in `submitted_at` order holds
/// other rows too and filters them out on the way. After a retest fan-out,
/// statistics that show a large pending-retest share made the planner pick
/// `idx_submissions_submitted_at`, walk it from the oldest row and filter out
/// every completed submission: 33 ms per poll on a 225k-row table. The
/// composite indexes lost on paper, because the planner discounts the heap
/// order of an index with more than one key column.
///
/// One key column, the sort key, makes the choice independent of the
/// statistics. The index holds a subset of the entries of
/// `idx_submissions_submitted_at`, in the same order, so a scan of it never
/// costs more on paper, and its predicate is the query's whole filter, so it
/// reads only the rows it returns. The predicate also keeps it empty in steady
/// state, and a fresh submission, which has no `retested_at`, never writes to
/// it. The literals are the raw values of `SubmissionStatus.pending` and
/// `APISubmission.Kind.student`.
struct CreatePendingRetestIndex: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else { return }

        try await sql.raw(
            """
            CREATE INDEX IF NOT EXISTS idx_submissions_pending_retest_submitted_at ON submissions(submitted_at) \
            WHERE status = 'pending' AND kind = 'student' AND retested_at IS NOT NULL
            """
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else { return }

        try await sql.raw("DROP INDEX IF EXISTS idx_submissions_pending_retest_submitted_at").run()
    }
}
