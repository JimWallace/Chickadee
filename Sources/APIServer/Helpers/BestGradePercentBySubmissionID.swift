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

import Core
import Fluent
import Foundation

// MARK: - Grade-carrying abstraction (#1157)

/// The three grade accessors the folds below need. `APIResult` conforms via
/// its column-first accessors; `GradeResultSummary` carries the same values
/// without ever loading `collection_json` — the audit found one CSV export
/// pulling hundreds of MB of blobs to read four scalar columns.
protocol GradeValueCarrying {
    var gradePercentValue: Int? { get }
    var gradePointsValue: Double? { get }
    var gradeTotalPointsValue: Double? { get }
}

extension APIResult: GradeValueCarrying {}

/// Blob-free projection of an `APIResult` for grade folds: the denormalized
/// grade columns plus identity/ordering fields, computed with the same math
/// as `APIResult`'s column-first accessors. Rows whose grade columns are all
/// nil (pre-backfill writes the migration couldn't parse) are hydrated by
/// the loader's legacy fallback, so the two paths can never disagree.
struct GradeResultSummary: Sendable, GradeValueCarrying {
    let resultID: String?
    let submissionID: String
    let source: String?
    let receivedAt: Date?
    let earnedPoints: Double?
    let totalPoints: Double?
    let passCount: Int?
    let totalTests: Int?
    /// Set only by the loader's legacy fallback, where the percent comes
    /// from parsing the blob rather than the (nil) grade columns.
    var legacyGradePercent: Int?

    var gradePercentValue: Int? {
        if let legacyGradePercent { return legacyGradePercent }
        if let earned = earnedPoints, let total = totalPoints, total > 0 {
            return GradePercent.of(earned: earned, total: total)
        }
        guard let pass = passCount, let total = totalTests else { return nil }
        return GradePercent.of(earned: Double(pass), total: Double(total))
    }

    var gradePointsValue: Double? {
        if let total = totalPoints, total > 0, let earned = earnedPoints { return earned }
        return passCount.map(Double.init)
    }

    var gradeTotalPointsValue: Double? {
        if let total = totalPoints, total > 0 { return total }
        return nil
    }
}

// MARK: - Policy (pure)

/// The highest `gradePercentValue` (0–100) across `results`, or nil when no
/// result carries a parseable percent.
func bestGradePercent(of results: some Sequence<some GradeValueCarrying>) -> Int? {
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
func bestGradeResult<T: GradeValueCarrying>(of results: some Sequence<T>) -> T? {
    results
        .filter { $0.gradePercentValue != nil }
        .max(by: { ($0.gradePercentValue ?? 0) < ($1.gradePercentValue ?? 0) })
}

/// The result row each submission's grade comes from: the highest-grade
/// row, or the newest row when none carries a parseable percent. `rows`
/// arrive newest-first, as the loaders return them. For the surfaces that
/// read a result ROW rather than a percent (the badge path needs the row's
/// collection), so a badge and the grade beside it read the same row (#1709).
func bestGradeResultBySubmissionID(_ rows: [APIResult]) -> [String: APIResult] {
    var grouped: [String: [APIResult]] = [:]
    for row in rows { grouped[row.submissionID, default: []].append(row) }
    return grouped.compactMapValues { bestGradeResult(of: $0) ?? $0.first }
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
        // Newest-first within each submission: the highest-grade fold is
        // order-independent, but `bestGradeResultBySubmissionID` falls back to
        // the first row for a submission with no graded result.
        let page = try await APIResult.query(on: db)
            .filter(\.$submissionID ~~ Array(ids[index..<end]))
            .sort(\.$receivedAt, .descending)
            .all()
        for result in page {
            grouped[result.submissionID, default: []].append(result)
        }
        index = end
    }
    return grouped
}

/// Blob-free loader (#1157): the grade projection of every result for the
/// given submission IDs, grouped by submission ID. Selects only the
/// denormalized grade columns + identity fields — never the collection
/// blob, which since #1173 lives in the `result_collections` side table
/// anyway. Chunked like `allResultsBySubmissionID`.
///
/// Legacy fallback: rows whose four grade columns are all nil (written
/// mid-deploy before the historical grade-columns backfill ran, or whose
/// blob that backfill couldn't parse) get their blob fetched from the side
/// table — normally zero rows — and are summarized via the blob-parsing
/// helpers so the projected and full paths can never disagree.
func gradeSummariesBySubmissionID(
    for submissionIDs: some Collection<String>,
    on db: Database
) async throws -> [String: [GradeResultSummary]] {
    guard !submissionIDs.isEmpty else { return [:] }
    let chunkSize = 5_000
    let ids = Array(submissionIDs)
    var grouped: [String: [GradeResultSummary]] = [:]
    var legacyRows: [APIResult] = []

    var index = ids.startIndex
    while index < ids.endIndex {
        let end =
            ids.index(index, offsetBy: chunkSize, limitedBy: ids.endIndex)
            ?? ids.endIndex
        let page = try await APIResult.query(on: db)
            .filter(\.$submissionID ~~ Array(ids[index..<end]))
            .field(\.$id)
            .field(\.$submissionID)
            .field(\.$source)
            .field(\.$earnedPoints)
            .field(\.$totalPoints)
            .field(\.$passCount)
            .field(\.$totalTests)
            .field(\.$receivedAt)
            .sort(\.$receivedAt, .descending)
            .all()
        for row in page {
            let allColumnsNil =
                row.earnedPoints == nil && row.totalPoints == nil
                && row.passCount == nil && row.totalTests == nil
            if allColumnsNil {
                legacyRows.append(row)
                continue
            }
            grouped[row.submissionID, default: []].append(
                GradeResultSummary(
                    resultID: row.id,
                    submissionID: row.submissionID,
                    source: row.source,
                    receivedAt: row.receivedAt,
                    earnedPoints: row.earnedPoints,
                    totalPoints: row.totalPoints,
                    passCount: row.passCount,
                    totalTests: row.totalTests
                ))
        }
        index = end
    }

    // Rare path: hydrate column-less rows from the blob (side table, #1173)
    // so their grades (if any) still participate in the folds.
    if !legacyRows.isEmpty {
        let blobByID = try await collectionJSONByResultID(
            for: legacyRows.compactMap(\.id), on: db)
        for row in legacyRows {
            // One decode per blob, not one per value.
            let fields = row.id.flatMap { blobByID[$0] }.flatMap(CollectionGradeFields.init(json:))
            grouped[row.submissionID, default: []].append(
                GradeResultSummary(
                    resultID: row.id,
                    submissionID: row.submissionID,
                    source: row.source,
                    receivedAt: row.receivedAt,
                    earnedPoints: fields?.gradePoints,
                    totalPoints: fields?.gradeTotalPoints,
                    passCount: row.passCount,
                    totalTests: row.totalTests,
                    legacyGradePercent: fields?.gradePercent
                ))
        }
    }
    return grouped
}

/// The highest `gradePercentValue` (0–100) per submission, across all result
/// sources — the blob-free loader + `bestGradePercent` fold in one call.
///
/// The map contains only submissions that have at least one parseable
/// `gradePercentValue`; missing entries mean no gradeable result exists yet.
func bestGradePercentBySubmissionID(
    for submissionIDs: some Collection<String>,
    on db: Database
) async throws -> [String: Int] {
    try await gradeSummariesBySubmissionID(for: submissionIDs, on: db)
        .compactMapValues { bestGradePercent(of: $0) }
}

/// `bestGradeResultBySubmissionID` over every result of the given
/// submissions, loaded in one chunked query.
func bestGradeResultBySubmissionID(
    for submissionIDs: some Collection<String>,
    on db: Database
) async throws -> [String: APIResult] {
    bestGradeResultBySubmissionID(
        try await allResultsBySubmissionID(for: submissionIDs, on: db).values.flatMap { $0 })
}
