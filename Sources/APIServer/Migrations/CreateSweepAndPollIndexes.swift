import Fluent
import SQLKit

/// Indexes for the periodic sweeps, the leaderboard poll and the webhook
/// lookup that `CreateHotPathIndexes` predates (#1800–#1804). Each query runs
/// on a timer or on every request against a table whose only index was the
/// unique the row's identity needed, so each one was a full scan.
struct CreateSweepAndPollIndexes: ChickadeeMigration {
    /// Index name to the `CREATE INDEX` tail, in creation order. One table
    /// so the test can assert every name exists without a second copy.
    static let indexes: [(name: String, on: String)] = [
        // AGS grade-sync sweep (every 60s): syncs pending a push, oldest
        // first. The twin of `idx_results_brightspace_pending`.
        ("idx_lti_grade_syncs_pending", "lti_grade_syncs(pending, pending_since)"),
        // Instructor LTI grades page: every sync for a set of assignments.
        ("idx_lti_grade_syncs_test_setup", "lti_grade_syncs(test_setup_id)"),
        // Union leaderboard body, polled every 5s while the window is open:
        // completed matches for one assignment, newest first.
        ("idx_match_results_setup_completed", "match_results(test_setup_id, completed_at)"),
        // Tournament page and the next-round scheduler: runs for one
        // assignment, latest first.
        ("idx_tournament_runs_setup_started", "tournament_runs(test_setup_id, started_at)"),
        // Achievement sweep (every 300s) and the corpus scheduler: the newest
        // completed corpus run for one assignment.
        ("idx_class_coverage_runs_setup_completed", "class_coverage_runs(test_setup_id, completed_at)"),
        // Push webhook: the course repository a GitHub repository ID names.
        // Plain, not unique: a GitHub repository ID is unique on GitHub's
        // side, and a constraint that failed to build would stop the server
        // at startup for a lookup that only needs to be fast.
        ("idx_github_course_repositories_repo", "github_course_repositories(repo_id)"),
        // Admin user page and the data export: one student's repositories.
        ("idx_github_course_repositories_user", "github_course_repositories(user_id)"),
        // Hourly LTI reaper: rows past their expiry. A consumed row expires
        // too, so one column serves both arms of its filter.
        ("idx_lti_login_states_expires", "lti_login_states(expires_at)"),
        ("idx_lti_deep_link_requests_expires", "lti_deep_link_requests(expires_at)"),
    ]

    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        for index in Self.indexes {
            try await sql.raw("CREATE INDEX IF NOT EXISTS \(unsafeRaw: index.name) ON \(unsafeRaw: index.on)").run()
        }
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        for index in Self.indexes.reversed() {
            try await sql.raw("DROP INDEX IF EXISTS \(unsafeRaw: index.name)").run()
        }
    }
}
