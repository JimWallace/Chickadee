// APIServer/Services/StudentSubmissionAggregates.swift
//
// SQL-side aggregation for the student dashboard's per-setup maps (#1382
// item 2). The dashboard used to load EVERY submission the student ever made
// across the visible setups, then every result row for all of them, only to
// fold both down to one latest pick, one count, and one best percent per
// setup — two unbounded reads that grow monotonically all term. These
// loaders push the folds into the database and return O(visible setups) rows.
//
// The grade fold mirrors `APIResult.gradePercentValue` (the #1085/#1111
// "highest grade wins" policy, branch for branch) through `GradePercentSQL`:
// the best full-mark and best partial raw percents come from SQL, and Swift
// rounds them once with the rule of `GradePercent.of`, which caps a partial
// mark at 99. Rows whose four grade columns are all nil contribute NULL, as
// the column-first accessor reports no grade for them.

import Fluent
import Foundation
import SQLKit

/// Per-setup submission summary for one student: the latest submission's id
/// and the total attempt count, computed by the database rather than by
/// materializing the full history.
struct StudentSetupSubmissionSummary {
    let latestSubmissionID: String
    let submissionCount: Int
}

/// `[setupID: summary]` for the student's submissions across `setupIDs`.
/// Latest means newest `submitted_at` (ties broken by attempt number), the
/// same order the pre-aggregate loader sorted by.
func studentSubmissionSummaryBySetup(
    userID: UUID, setupIDs: [String], on db: any Database
) async throws -> [String: StudentSetupSubmissionSummary] {
    guard !setupIDs.isEmpty else { return [:] }
    guard let sql = db as? (any SQLDatabase) else {
        throw AppError.internalFailure(reason: "The submission summary needs a SQL database.")
    }
    struct SummaryRow: Decodable {
        let testSetupID: String
        let id: String
        let total: Int
        enum CodingKeys: String, CodingKey {
            case testSetupID = "test_setup_id"
            case id
            case total
        }
    }
    let rows = try await sql.raw(
        """
        SELECT test_setup_id, id, total FROM (
            SELECT test_setup_id, id,
                ROW_NUMBER() OVER (
                    PARTITION BY test_setup_id
                    ORDER BY submitted_at DESC, attempt_number DESC
                ) AS rn,
                COUNT(*) OVER (PARTITION BY test_setup_id) AS total
            FROM \(unsafeRaw: APISubmission.schema)
            WHERE user_id = \(bind: userID)
              AND kind = \(bind: APISubmission.Kind.student)
              AND test_setup_id IN (\(binds: setupIDs))
        ) ranked
        WHERE rn = 1
        """
    ).all(decoding: SummaryRow.self)
    return rows.reduce(into: [:]) {
        $0[$1.testSetupID] = StudentSetupSubmissionSummary(
            latestSubmissionID: $1.id, submissionCount: $1.total)
    }
}

/// The highest grade percent per setup across every result of every student
/// submission — `bestGradePercent(of:)` pushed into SQL. Setups with no
/// gradeable result are absent from the map, and so is a best of exactly 0:
/// the fold this replaces only admitted a grade when it exceeded the 0
/// sentinel, so an all-fail student shows no grade rather than "0%" — kept
/// bit-for-bit so the rewrite is invisible.
func studentBestGradePercentBySetup(
    userID: UUID, setupIDs: [String], on db: any Database
) async throws -> [String: Int] {
    guard !setupIDs.isEmpty else { return [:] }
    guard let sql = db as? (any SQLDatabase) else {
        throw AppError.internalFailure(reason: "The best grade read needs a SQL database.")
    }
    struct BestRow: Decodable {
        let testSetupID: String
        let bestFull: Double?
        let bestPartial: Double?
        enum CodingKeys: String, CodingKey {
            case testSetupID = "test_setup_id"
            case bestFull = "best_full"
            case bestPartial = "best_partial"
        }
    }
    // CAST(... AS DOUBLE PRECISION) resolves to an 8-byte IEEE double on both
    // dialects (SQLite's "DOUB" affinity rule), and the operand order matches
    // the accessor's `Double(pass) / Double(total) * 100` exactly, so the SQL
    // fraction is bit-identical to the Swift one.
    let rows = try await sql.raw(
        """
        SELECT s.test_setup_id AS test_setup_id,
            \(GradePercentSQL.foldColumns)
        FROM \(unsafeRaw: APIResult.schema) r
        INNER JOIN \(unsafeRaw: APISubmission.schema) s ON s.id = r.submission_id
        WHERE s.user_id = \(bind: userID)
          AND s.kind = \(bind: APISubmission.Kind.student)
          AND s.test_setup_id IN (\(binds: setupIDs))
        GROUP BY s.test_setup_id
        """
    ).all(decoding: BestRow.self)
    var best: [String: Int] = [:]
    for row in rows {
        guard let percent = GradePercentSQL.percent(bestFull: row.bestFull, bestPartial: row.bestPartial)
        else { continue }
        if percent > 0 { best[row.testSetupID] = percent }
    }
    return best
}

// MARK: - By-student variants (instructor roster, #1382 item 6)

/// Per-student submission summary for one assignment's setup: the latest
/// submission's id and time, and the attempt count —
/// `studentSubmissionSummaryBySetup` partitioned by student instead of by
/// setup, for the instructor assignment-submissions roster. The time comes
/// from the same ranked row, so the roster needs no second read by id.
struct SetupStudentSubmissionSummary {
    let latestSubmissionID: String
    let latestSubmittedAt: Date?
    let submissionCount: Int
}

func submissionSummaryByStudent(
    setupID: String, studentIDs: [UUID], on db: any Database
) async throws -> [UUID: SetupStudentSubmissionSummary] {
    guard !studentIDs.isEmpty else { return [:] }
    guard let sql = db as? (any SQLDatabase) else {
        throw AppError.internalFailure(reason: "The submission summary needs a SQL database.")
    }
    struct SummaryRow: Decodable {
        let userID: UUID
        let id: String
        let submittedAt: Date?
        let total: Int
        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case id
            case submittedAt = "submitted_at"
            case total
        }
    }
    let rows = try await sql.raw(
        """
        SELECT user_id, id, submitted_at, total FROM (
            SELECT user_id, id, submitted_at,
                ROW_NUMBER() OVER (
                    PARTITION BY user_id
                    ORDER BY submitted_at DESC, attempt_number DESC
                ) AS rn,
                COUNT(*) OVER (PARTITION BY user_id) AS total
            FROM \(unsafeRaw: APISubmission.schema)
            WHERE test_setup_id = \(bind: setupID)
              AND kind = \(bind: APISubmission.Kind.student)
              AND user_id IN (\(binds: studentIDs))
        ) ranked
        WHERE rn = 1
        """
    ).all(decoding: SummaryRow.self)
    return rows.reduce(into: [:]) {
        $0[$1.userID] = SetupStudentSubmissionSummary(
            latestSubmissionID: $1.id, latestSubmittedAt: $1.submittedAt, submissionCount: $1.total)
    }
}

/// The highest grade percent per student across every result of their
/// submissions to one setup. Unlike the dashboard's by-setup fold, a best of
/// exactly 0 IS kept: the roster fold this replaces admitted any grade at or
/// above 0 (`best >= 0`), so an all-fail student shows "0%" to their
/// instructor rather than no grade. Students with no gradeable result are
/// absent.
func bestGradePercentByStudent(
    setupID: String, studentIDs: [UUID], on db: any Database
) async throws -> [UUID: Int] {
    guard !studentIDs.isEmpty else { return [:] }
    guard let sql = db as? (any SQLDatabase) else {
        throw AppError.internalFailure(reason: "The best grade read needs a SQL database.")
    }
    struct BestRow: Decodable {
        let userID: UUID
        let bestFull: Double?
        let bestPartial: Double?
        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case bestFull = "best_full"
            case bestPartial = "best_partial"
        }
    }
    let rows = try await sql.raw(
        """
        SELECT s.user_id AS user_id,
            \(GradePercentSQL.foldColumns)
        FROM \(unsafeRaw: APIResult.schema) r
        INNER JOIN \(unsafeRaw: APISubmission.schema) s ON s.id = r.submission_id
        WHERE s.test_setup_id = \(bind: setupID)
          AND s.kind = \(bind: APISubmission.Kind.student)
          AND s.user_id IN (\(binds: studentIDs))
        GROUP BY s.user_id
        """
    ).all(decoding: BestRow.self)
    var best: [UUID: Int] = [:]
    for row in rows {
        guard let percent = GradePercentSQL.percent(bestFull: row.bestFull, bestPartial: row.bestPartial)
        else { continue }
        best[row.userID] = percent
    }
    return best
}
