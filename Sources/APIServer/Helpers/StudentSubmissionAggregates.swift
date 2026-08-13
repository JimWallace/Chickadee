// APIServer/Helpers/StudentSubmissionAggregates.swift
//
// SQL-side aggregation for the student dashboard's per-setup maps (#1382
// item 2). The dashboard used to load EVERY submission the student ever made
// across the visible setups, then every result row for all of them, only to
// fold both down to one latest pick, one count, and one best percent per
// setup — two unbounded reads that grow monotonically all term. These
// loaders push the folds into the database and return O(visible setups) rows.
//
// The grade fold mirrors `APIResult.gradePercentValue` (the #1085/#1111
// "highest grade wins" policy, branch for branch): MAX is taken over the raw
// per-row fraction and rounded ONCE in Swift with the same `.rounded()` the
// accessor uses. Rounding is monotone, so max-then-round equals
// round-then-max — the SQL never re-implements the rounding and the two
// paths cannot disagree on a boundary like 87.5. Rows whose four grade
// columns are all nil contribute NULL to the MAX, exactly as the
// column-first accessor reports no grade for them.

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
    userID: UUID, setupIDs: [String], on db: Database
) async throws -> [String: StudentSetupSubmissionSummary] {
    guard !setupIDs.isEmpty else { return [:] }
    guard let sql = db as? SQLDatabase else {
        return try await studentSubmissionSummaryBySetupViaFluent(
            userID: userID, setupIDs: setupIDs, on: db)
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
    userID: UUID, setupIDs: [String], on db: Database
) async throws -> [String: Int] {
    guard !setupIDs.isEmpty else { return [:] }
    guard let sql = db as? SQLDatabase else {
        return try await studentBestGradePercentBySetupViaFluent(
            userID: userID, setupIDs: setupIDs, on: db)
    }
    struct BestRow: Decodable {
        let testSetupID: String
        let bestFraction: Double?
        enum CodingKeys: String, CodingKey {
            case testSetupID = "test_setup_id"
            case bestFraction = "best_fraction"
        }
    }
    // CAST(... AS DOUBLE PRECISION) resolves to an 8-byte IEEE double on both
    // dialects (SQLite's "DOUB" affinity rule), and the operand order matches
    // the accessor's `Double(pass) / Double(total) * 100` exactly, so the SQL
    // fraction is bit-identical to the Swift one.
    let rows = try await sql.raw(
        """
        SELECT s.test_setup_id AS test_setup_id,
            MAX(CASE
                WHEN r.total_points > 0 AND r.earned_points IS NOT NULL
                    THEN r.earned_points / r.total_points * 100
                WHEN r.total_tests > 0 AND r.pass_count IS NOT NULL
                    THEN CAST(r.pass_count AS DOUBLE PRECISION)
                        / CAST(r.total_tests AS DOUBLE PRECISION) * 100
            END) AS best_fraction
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
        guard let fraction = row.bestFraction else { continue }
        let percent = Int(fraction.rounded())
        if percent > 0 { best[row.testSetupID] = percent }
    }
    return best
}

// MARK: - By-student variants (instructor roster, #1382 item 6)

/// Per-student submission summary for one assignment's setup: the latest
/// submission's id and the attempt count — `studentSubmissionSummaryBySetup`
/// partitioned by student instead of by setup, for the instructor
/// assignment-submissions roster.
struct SetupStudentSubmissionSummary {
    let latestSubmissionID: String
    let submissionCount: Int
}

func submissionSummaryByStudent(
    setupID: String, studentIDs: [UUID], on db: Database
) async throws -> [UUID: SetupStudentSubmissionSummary] {
    guard !studentIDs.isEmpty else { return [:] }
    guard let sql = db as? SQLDatabase else {
        return try await submissionSummaryByStudentViaFluent(
            setupID: setupID, studentIDs: studentIDs, on: db)
    }
    struct SummaryRow: Decodable {
        let userID: UUID
        let id: String
        let total: Int
        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case id
            case total
        }
    }
    let rows = try await sql.raw(
        """
        SELECT user_id, id, total FROM (
            SELECT user_id, id,
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
            latestSubmissionID: $1.id, submissionCount: $1.total)
    }
}

/// The highest grade percent per student across every result of their
/// submissions to one setup. Unlike the dashboard's by-setup fold, a best of
/// exactly 0 IS kept: the roster fold this replaces admitted any grade at or
/// above 0 (`best >= 0`), so an all-fail student shows "0%" to their
/// instructor rather than no grade. Students with no gradeable result are
/// absent.
func bestGradePercentByStudent(
    setupID: String, studentIDs: [UUID], on db: Database
) async throws -> [UUID: Int] {
    guard !studentIDs.isEmpty else { return [:] }
    guard let sql = db as? SQLDatabase else {
        return try await bestGradePercentByStudentViaFluent(
            setupID: setupID, studentIDs: studentIDs, on: db)
    }
    struct BestRow: Decodable {
        let userID: UUID
        let bestFraction: Double?
        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case bestFraction = "best_fraction"
        }
    }
    let rows = try await sql.raw(
        """
        SELECT s.user_id AS user_id,
            MAX(CASE
                WHEN r.total_points > 0 AND r.earned_points IS NOT NULL
                    THEN r.earned_points / r.total_points * 100
                WHEN r.total_tests > 0 AND r.pass_count IS NOT NULL
                    THEN CAST(r.pass_count AS DOUBLE PRECISION)
                        / CAST(r.total_tests AS DOUBLE PRECISION) * 100
            END) AS best_fraction
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
        guard let fraction = row.bestFraction else { continue }
        best[row.userID] = Int(fraction.rounded())
    }
    return best
}

// MARK: - Non-SQL fallbacks
//
// Not hit by the sqlite/postgres drivers in use; they load the rows and run
// the identical folds in Swift.

private func studentSubmissionSummaryBySetupViaFluent(
    userID: UUID, setupIDs: [String], on db: Database
) async throws -> [String: StudentSetupSubmissionSummary] {
    let rows = try await APISubmission.query(on: db)
        .filter(\.$userID == userID)
        .filter(\.$testSetupID ~~ setupIDs)
        .filter(\.$kind == APISubmission.Kind.student)
        .sort(\.$submittedAt, .descending)
        .sort(\.$attemptNumber, .descending)
        .field(\.$id)
        .field(\.$testSetupID)
        .all()
    var summary: [String: StudentSetupSubmissionSummary] = [:]
    for row in rows {
        guard let id = row.id else { continue }
        if let existing = summary[row.testSetupID] {
            summary[row.testSetupID] = StudentSetupSubmissionSummary(
                latestSubmissionID: existing.latestSubmissionID,
                submissionCount: existing.submissionCount + 1)
        } else {
            summary[row.testSetupID] = StudentSetupSubmissionSummary(
                latestSubmissionID: id, submissionCount: 1)
        }
    }
    return summary
}

private func submissionSummaryByStudentViaFluent(
    setupID: String, studentIDs: [UUID], on db: Database
) async throws -> [UUID: SetupStudentSubmissionSummary] {
    let rows = try await APISubmission.query(on: db)
        .filter(\.$testSetupID == setupID)
        .filter(\.$kind == APISubmission.Kind.student)
        .filter(\.$userID ~~ studentIDs)
        .sort(\.$submittedAt, .descending)
        .sort(\.$attemptNumber, .descending)
        .field(\.$id)
        .field(\.$userID)
        .all()
    var summary: [UUID: SetupStudentSubmissionSummary] = [:]
    for row in rows {
        guard let id = row.id, let userID = row.userID else { continue }
        if let existing = summary[userID] {
            summary[userID] = SetupStudentSubmissionSummary(
                latestSubmissionID: existing.latestSubmissionID,
                submissionCount: existing.submissionCount + 1)
        } else {
            summary[userID] = SetupStudentSubmissionSummary(
                latestSubmissionID: id, submissionCount: 1)
        }
    }
    return summary
}

private func bestGradePercentByStudentViaFluent(
    setupID: String, studentIDs: [UUID], on db: Database
) async throws -> [UUID: Int] {
    let submissions = try await APISubmission.query(on: db)
        .filter(\.$testSetupID == setupID)
        .filter(\.$kind == APISubmission.Kind.student)
        .filter(\.$userID ~~ studentIDs)
        .field(\.$id)
        .field(\.$userID)
        .all()
    var studentBySubmissionID: [String: UUID] = [:]
    for submission in submissions {
        guard let id = submission.id, let userID = submission.userID else { continue }
        studentBySubmissionID[id] = userID
    }
    guard !studentBySubmissionID.isEmpty else { return [:] }
    let results = try await APIResult.query(on: db)
        .filter(\.$submissionID ~~ Array(studentBySubmissionID.keys))
        .all()
    var best: [UUID: Int] = [:]
    for row in results {
        guard let userID = studentBySubmissionID[row.submissionID],
            let pct = row.gradePercentValue
        else { continue }
        if pct > (best[userID] ?? -1) { best[userID] = pct }
    }
    return best
}

private func studentBestGradePercentBySetupViaFluent(
    userID: UUID, setupIDs: [String], on db: Database
) async throws -> [String: Int] {
    let submissions = try await APISubmission.query(on: db)
        .filter(\.$userID == userID)
        .filter(\.$testSetupID ~~ setupIDs)
        .filter(\.$kind == APISubmission.Kind.student)
        .field(\.$id)
        .field(\.$testSetupID)
        .all()
    var setupBySubmissionID: [String: String] = [:]
    for submission in submissions {
        guard let id = submission.id else { continue }
        setupBySubmissionID[id] = submission.testSetupID
    }
    guard !setupBySubmissionID.isEmpty else { return [:] }
    let results = try await APIResult.query(on: db)
        .filter(\.$submissionID ~~ Array(setupBySubmissionID.keys))
        .all()
    var best: [String: Int] = [:]
    for row in results {
        guard let setupID = setupBySubmissionID[row.submissionID],
            let pct = row.gradePercentValue
        else { continue }
        if pct > (best[setupID] ?? 0) { best[setupID] = pct }
    }
    return best
}
