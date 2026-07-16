// APIServer/Helpers/PreferredResultsBySubmissionID.swift
//
// Shared result-preference fold used by the per-student history pages and
// the achievement sweep.  The instructor submissions/roster page and the
// grades CSV export now use `bestGradePercentBySubmissionID` instead, which
// takes the highest percentage across ALL sources rather than preferring
// the worker result.

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
    // Loading goes through the shared chunked loader (#1118), which returns
    // each submission's results newest-first — the order this fold's
    // "first worker result wins, else first result" rule depends on.
    let grouped = try await allResultsBySubmissionID(for: submissionIDs, on: db)

    var preferredResultBySubmissionID: [String: APIResult] = [:]
    for (key, results) in grouped {
        for result in results {
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
    }
    return preferredResultBySubmissionID
}

/// Blob-free variant of the worker-preferred fold (#1160): identical
/// preference rule over `GradeResultSummary` rows, for consumers that only
/// read grade values (the class-goal achievement sweep). Groups are
/// re-sorted newest-first before folding because the summary loader's
/// legacy-row fallback can append out of order.
func preferredGradeSummariesBySubmissionID(
    for submissionIDs: [String],
    on db: Database
) async throws -> [String: GradeResultSummary] {
    let grouped = try await gradeSummariesBySubmissionID(for: submissionIDs, on: db)

    var preferredBySubmissionID: [String: GradeResultSummary] = [:]
    for (key, unsorted) in grouped {
        let results = unsorted.sorted {
            ($0.receivedAt ?? .distantPast) > ($1.receivedAt ?? .distantPast)
        }
        for result in results {
            if let existing = preferredBySubmissionID[key] {
                let existingSource = existing.source ?? "worker"
                let candidateSource = result.source ?? "worker"
                if existingSource == "worker" { continue }
                if candidateSource == "worker" {
                    preferredBySubmissionID[key] = result
                }
            } else {
                preferredBySubmissionID[key] = result
            }
        }
    }
    return preferredBySubmissionID
}
