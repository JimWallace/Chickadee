// APIServer/Services/BestGradePercentByStudentAndSetup.swift
//
// The highest grade percent per (student, setup), folded in the database: the
// grades CSV export's whole-course read. The export used to hydrate every
// student submission of the course and every result of those submissions as
// Fluent models (44,000 rows at one course's scale, 2.6 s, almost all of it
// hydration on the event loop) to fold them down to one number per student
// and assignment. This returns that one number per pair.
//
// The fold is `GradePercentSQL`, so the result equals `bestGradePercent(of:)`
// over the same rows. A result whose four grade columns are all NULL (written
// before the grade-columns backfill, normally none) is graded from its stored
// collection, as `gradeSummariesBySubmissionID` does, so the two paths cannot
// disagree.

import Core
import Fluent
import Foundation
import SQLKit

/// One student's grade cell for one setup.
struct StudentSetupKey: Hashable, Sendable {
    let userID: UUID
    let setupID: String
}

/// `[(student, setup): best percent]` over every result of every student
/// submission to `setupIDs` by `studentIDs`. A pair with no gradeable result
/// is absent; a best of 0 is kept.
func bestGradePercentByStudentAndSetup(
    setupIDs: [String], studentIDs: [UUID], on db: any Database
) async throws -> [StudentSetupKey: Int] {
    guard !setupIDs.isEmpty, !studentIDs.isEmpty else { return [:] }
    guard let sql = db as? (any SQLDatabase) else {
        return try await bestGradePercentByStudentAndSetupViaFluent(
            setupIDs: setupIDs, studentIDs: studentIDs, on: db)
    }
    struct BestRow: Decodable {
        let userID: UUID
        let testSetupID: String
        let bestFull: Double?
        let bestPartial: Double?
        let hasLegacy: Bool
        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case testSetupID = "test_setup_id"
            case bestFull = "best_full"
            case bestPartial = "best_partial"
            case hasLegacy = "has_legacy"
        }
    }

    var best: [StudentSetupKey: Int] = [:]
    var legacyKeys: Set<StudentSetupKey> = []
    for chunk in chunkedForInFilter(studentIDs) {
        // `BOOL_OR` is Postgres; `GradeSourceDisagreement` assumes it too.
        let rows = try await sql.raw(
            """
            SELECT s.user_id AS user_id, s.test_setup_id AS test_setup_id,
                \(GradePercentSQL.foldColumns),
                BOOL_OR(r.earned_points IS NULL AND r.total_points IS NULL
                    AND r.pass_count IS NULL AND r.total_tests IS NULL) AS has_legacy
            FROM \(unsafeRaw: APIResult.schema) r
            INNER JOIN \(unsafeRaw: APISubmission.schema) s ON s.id = r.submission_id
            WHERE s.kind = \(bind: APISubmission.Kind.student)
              AND s.test_setup_id IN (\(binds: setupIDs))
              AND s.user_id IN (\(binds: chunk))
            GROUP BY s.user_id, s.test_setup_id
            """
        ).all(decoding: BestRow.self)
        for row in rows {
            let key = StudentSetupKey(userID: row.userID, setupID: row.testSetupID)
            if let percent = GradePercentSQL.percent(bestFull: row.bestFull, bestPartial: row.bestPartial) {
                best[key] = percent
            }
            if row.hasLegacy { legacyKeys.insert(key) }
        }
    }

    // Rare path: grade the pairs that hold a column-less result from their
    // stored collections, and keep the higher of the two.
    if !legacyKeys.isEmpty {
        let legacyBest = try await bestGradePercentByStudentAndSetupViaFluent(
            setupIDs: Array(Set(legacyKeys.map(\.setupID))),
            studentIDs: Array(Set(legacyKeys.map(\.userID))), on: db)
        for key in legacyKeys {
            guard let percent = legacyBest[key] else { continue }
            if percent > (best[key] ?? -1) { best[key] = percent }
        }
    }
    return best
}

/// The same fold over hydrated rows: the non-SQL path, and the legacy
/// fallback above. `gradeSummariesBySubmissionID` reads only the grade
/// columns, and the stored collection for a column-less row.
private func bestGradePercentByStudentAndSetupViaFluent(
    setupIDs: [String], studentIDs: [UUID], on db: any Database
) async throws -> [StudentSetupKey: Int] {
    var keyBySubmissionID: [String: StudentSetupKey] = [:]
    for chunk in chunkedForInFilter(studentIDs) {
        let submissions = try await APISubmission.query(on: db)
            .filter(\.$kind == APISubmission.Kind.student)
            .filter(\.$testSetupID ~~ setupIDs)
            .filter(\.$userID ~~ chunk)
            .field(\.$id)
            .field(\.$userID)
            .field(\.$testSetupID)
            .all()
        for submission in submissions {
            guard let id = submission.id, let userID = submission.userID else { continue }
            keyBySubmissionID[id] = StudentSetupKey(userID: userID, setupID: submission.testSetupID)
        }
    }
    guard !keyBySubmissionID.isEmpty else { return [:] }
    let summaries = try await gradeSummariesBySubmissionID(for: Array(keyBySubmissionID.keys), on: db)
    var best: [StudentSetupKey: Int] = [:]
    for (submissionID, results) in summaries {
        guard let key = keyBySubmissionID[submissionID], let percent = bestGradePercent(of: results)
        else { continue }
        if percent > (best[key] ?? -1) { best[key] = percent }
    }
    return best
}
