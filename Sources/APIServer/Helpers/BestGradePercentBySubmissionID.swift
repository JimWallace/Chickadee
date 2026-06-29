// APIServer/Helpers/BestGradePercentBySubmissionID.swift
//
// Shared "highest grade wins" fold used by the student dashboard, the
// instructor submissions page, the grades CSV export, and the BrightSpace
// grade sync.  All four surfaces must agree on the effective grade, and the
// policy is: take the best gradePercentValue across EVERY result for a
// submission, regardless of source (browser or worker).

import Fluent

/// Loads every `APIResult` for the given submission IDs and returns the
/// highest `gradePercentValue` (0–100) per submission, across all result
/// sources.  A browser result at 100 % is never displaced by a later worker
/// result at a lower percentage.
///
/// The map contains only submissions that have at least one parseable
/// `gradePercentValue`; missing entries mean no gradeable result exists yet.
func bestGradePercentBySubmissionID(
    for submissionIDs: some Collection<String>,
    on db: Database
) async throws -> [String: Int] {
    guard !submissionIDs.isEmpty else { return [:] }
    // Chunk to stay under bind-parameter limits (SQLite 32k, Postgres 65,535).
    let chunkSize = 5_000
    let ids = Array(submissionIDs)
    var all: [APIResult] = []
    var index = ids.startIndex
    while index < ids.endIndex {
        let end =
            ids.index(index, offsetBy: chunkSize, limitedBy: ids.endIndex)
            ?? ids.endIndex
        all += try await APIResult.query(on: db)
            .filter(\.$submissionID ~~ Array(ids[index..<end]))
            .all()
        index = end
    }
    var best: [String: Int] = [:]
    for result in all {
        guard let pct = result.gradePercentValue else { continue }
        if pct > (best[result.submissionID] ?? -1) {
            best[result.submissionID] = pct
        }
    }
    return best
}
