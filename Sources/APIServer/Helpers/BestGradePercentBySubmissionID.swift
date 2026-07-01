// APIServer/Helpers/BestGradePercentBySubmissionID.swift
//
// The ONE place the "highest grade wins" policy lives (#1085, #1111). All
// grade-displaying surfaces — student dashboard, instructor roster, the
// per-student drilldown pages, the grades CSV export, and the BrightSpace
// grade sync — must agree on the effective grade, and the policy is: take
// the best grade across EVERY result for a submission, regardless of source
// (browser or worker). A 100 % browser result is never displaced by a later
// lower-percentage worker regrade.
//
// Policy (the pure folds below) is split from I/O (the chunked loaders) so
// a surface that already holds the rows applies the identical fold instead
// of re-implementing it inline — the drift that produced #1111's stale
// per-student drilldown grade.

import Fluent

// MARK: - Policy (pure)

/// The highest `gradePercentValue` (0–100) across `results`, or nil when no
/// result carries a parseable percent.
func bestGradePercent(of results: some Sequence<APIResult>) -> Int? {
    var best: Int?
    for result in results {
        guard let pct = result.gradePercentValue else { continue }
        if pct > (best ?? -1) { best = pct }
    }
    return best
}

/// The result row that wins "highest grade" — for callers that need the
/// winning row's exact points rather than the lossy Int percent (the
/// BrightSpace points push: 6/7 → 86 % → 8.6 instead of 8.57). Nil when no
/// result carries a parseable percent. Tie-breaking matches `max(by:)`
/// (the last of the tied rows wins), preserving the pre-#1111 behaviour of
/// the BrightSpace inline copy.
func bestGradeResult(of results: some Sequence<APIResult>) -> APIResult? {
    results
        .filter { $0.gradePercentValue != nil }
        .max(by: { ($0.gradePercentValue ?? 0) < ($1.gradePercentValue ?? 0) })
}

// MARK: - Loaders (I/O)

/// Loads every `APIResult` for the given submission IDs, grouped by
/// submission ID. Keeps ALL sources (browser + worker) so callers can apply
/// the highest-grade fold across them. Chunked to stay under bind-parameter
/// limits (SQLite 32k, Postgres 65,535).
func allResultsBySubmissionID(
    for submissionIDs: some Collection<String>,
    on db: Database
) async throws -> [String: [APIResult]] {
    guard !submissionIDs.isEmpty else { return [:] }
    let chunkSize = 5_000
    let ids = Array(submissionIDs)
    var grouped: [String: [APIResult]] = [:]
    var index = ids.startIndex
    while index < ids.endIndex {
        let end =
            ids.index(index, offsetBy: chunkSize, limitedBy: ids.endIndex)
            ?? ids.endIndex
        let page = try await APIResult.query(on: db)
            .filter(\.$submissionID ~~ Array(ids[index..<end]))
            .all()
        for result in page {
            grouped[result.submissionID, default: []].append(result)
        }
        index = end
    }
    return grouped
}

/// Loads every `APIResult` for the given submission IDs and returns the
/// highest `gradePercentValue` (0–100) per submission, across all result
/// sources — the loader + `bestGradePercent` fold in one call.
///
/// The map contains only submissions that have at least one parseable
/// `gradePercentValue`; missing entries mean no gradeable result exists yet.
func bestGradePercentBySubmissionID(
    for submissionIDs: some Collection<String>,
    on db: Database
) async throws -> [String: Int] {
    try await allResultsBySubmissionID(for: submissionIDs, on: db)
        .compactMapValues { bestGradePercent(of: $0) }
}
