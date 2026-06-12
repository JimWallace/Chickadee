// APIServer/Helpers/PreferredResultsBySubmissionID.swift
//
// Shared result-preference fold used by the instructor submissions/roster
// pages, the grades CSV export, the per-student history pages, and the
// achievement sweep.  Moved here from
// InstructorDashboardRoutes+Submissions.swift (audit 2026-06) so its home
// matches its module-wide callers — no behaviour changes.

import Fluent

/// Loads `APIResult` rows for the given submission IDs and reduces them
/// to one preferred result per submission, preferring `source == "worker"`
/// over a browser-runner submission when both exist.  Promoted to a free
/// function in v0.4.177 so the submissions and per-student views can
/// share it across `RouteCollection`s.
func preferredResultsBySubmissionID(
    for submissionIDs: [String],
    on db: Database
) async throws -> [String: APIResult] {
    // Chunk the IN-list: a term-scale grades export can pass 100k+ IDs, which
    // exceeds bind-parameter limits (SQLite 32k variables, Postgres 65,535
    // wire parameters) in a single query. Each submission's results live
    // entirely inside the chunk holding its ID, so the fold below is
    // order-equivalent to the unchunked query.
    let chunkSize = 5_000
    var results: [APIResult] = []
    var index = submissionIDs.startIndex
    while index < submissionIDs.endIndex {
        let end =
            submissionIDs.index(index, offsetBy: chunkSize, limitedBy: submissionIDs.endIndex)
            ?? submissionIDs.endIndex
        results.append(
            contentsOf: try await APIResult.query(on: db)
                .filter(\.$submissionID ~~ Array(submissionIDs[index..<end]))
                .sort(\.$receivedAt, .descending)
                .all())
        index = end
    }

    var preferredResultBySubmissionID: [String: APIResult] = [:]
    for result in results {
        let key = result.submissionID
        if let existing = preferredResultBySubmissionID[key] {
            let existingSource = existing.source ?? "worker"
            let candidateSource = result.source ?? "worker"
            if existingSource == "worker" { continue }
            if candidateSource == "worker" {
                preferredResultBySubmissionID[key] = result
            }
        } else {
            preferredResultBySubmissionID[key] = result
        }
    }
    return preferredResultBySubmissionID
}
