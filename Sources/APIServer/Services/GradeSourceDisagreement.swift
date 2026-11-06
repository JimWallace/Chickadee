// APIServer/Services/GradeSourceDisagreement.swift
//
// Where a submission's browser grade and its native grade differ.
//
// A browser grade is a participation grade (docs/grading-integrity.md, D8):
// the student's browser builds the result, and the server keeps it. A native
// run of the same submission happens only on a browser failover or an
// instructor retest. When both exist and differ, staff should see it: the
// browser result may be forged, or the two graders may really differ. It is a
// signal for the instructor, not an accusation, and it changes no grade. The
// best grade still wins (`bestGradePercent`), so a forged 100 % would
// otherwise hide a lower native result with no trace on any page.

import Fluent
import Foundation
import SQLKit

/// One submission's browser grade and native grade, when they differ.
struct GradeSourceDisagreement: Sendable, Equatable, Encodable {
    /// The best grade among the submission's browser results.
    let browserPercent: Int
    /// The grade of the newest native result: the latest retest.
    let nativePercent: Int
}

/// The disagreement among one submission's results, or nil when the
/// submission lacks a browser or a native result with a grade, or when the
/// two grades are equal.
///
/// A result is a browser result when its `source` is `APIResult.browserSource`;
/// every other result, a legacy row with no source included, is native.
///
/// The browser side is the best browser grade, the one that counts today. The
/// native side is the newest native result, so a later retest replaces an
/// earlier one; a row with no receive time counts as the oldest.
func gradeSourceDisagreement(of results: some Sequence<GradeResultSummary>) -> GradeSourceDisagreement? {
    var browserBest: Int?
    var newestNative: (receivedAt: Date, percent: Int)?
    for result in results {
        guard let percent = result.gradePercentValue else { continue }
        if result.source == APIResult.browserSource {
            browserBest = max(browserBest ?? percent, percent)
        } else {
            let receivedAt = result.receivedAt ?? .distantPast
            if newestNative.map({ receivedAt >= $0.receivedAt }) ?? true {
                newestNative = (receivedAt, percent)
            }
        }
    }
    guard let browserBest, let newestNative, browserBest != newestNative.percent else { return nil }
    return GradeSourceDisagreement(browserPercent: browserBest, nativePercent: newestNative.percent)
}

/// `gradeSourceDisagreement` for each submission in `summaries`, keyed by
/// submission ID. Submissions that agree, or that have only one source, are
/// absent.
func gradeSourceDisagreementBySubmissionID(
    _ summaries: [String: [GradeResultSummary]]
) -> [String: GradeSourceDisagreement] {
    summaries.compactMapValues { gradeSourceDisagreement(of: $0) }
}

/// The best grade and the source disagreement of each submission, from one
/// load of its result rows: what a staff history page shows. The best grade
/// is `bestGradePercentBySubmissionID`'s, so this page and every other show
/// the same number (#1111).
func bestGradePercentAndSourceDisagreementBySubmissionID(
    for submissionIDs: some Collection<String>,
    on db: any Database
) async throws -> (best: [String: Int], disagreements: [String: GradeSourceDisagreement]) {
    let summaries = try await gradeSummariesBySubmissionID(for: submissionIDs, on: db)
    return (
        summaries.compactMapValues { bestGradePercent(of: $0) },
        gradeSourceDisagreementBySubmissionID(summaries)
    )
}

/// The students, among `studentIDs`, with at least one submission to the setup
/// whose browser and native grades differ.
///
/// The roster page renders during a deadline, so this reads no result of a
/// submission graded by one source only. SQL first finds the submissions with
/// both a browser result and a native result, usually only those an instructor
/// retested; the grade rule then runs on those alone.
func studentsWithGradeSourceDisagreement(
    setupID: String, studentIDs: [UUID], on db: any Database
) async throws -> Set<UUID> {
    guard !studentIDs.isEmpty else { return [] }
    // The flag is advisory, and the roster must render whatever happens to
    // it: on a database without SQL, flag no one rather than fail the page.
    guard let sql = db as? (any SQLDatabase) else { return [] }
    struct BothSourcesRow: Decodable {
        let submissionID: String
        let userID: UUID
        enum CodingKeys: String, CodingKey {
            case submissionID = "submission_id"
            case userID = "user_id"
        }
    }
    let rows = try await sql.raw(
        """
        SELECT r.submission_id AS submission_id, s.user_id AS user_id
        FROM \(unsafeRaw: APIResult.schema) r
        INNER JOIN \(unsafeRaw: APISubmission.schema) s ON s.id = r.submission_id
        WHERE s.test_setup_id = \(bind: setupID)
          AND s.kind = \(bind: APISubmission.Kind.student)
          AND s.user_id IN (\(binds: studentIDs))
        GROUP BY r.submission_id, s.user_id
        HAVING BOOL_OR(r.source = \(bind: APIResult.browserSource))
           AND BOOL_OR(r.source IS NULL OR r.source <> \(bind: APIResult.browserSource))
        """
    ).all(decoding: BothSourcesRow.self)
    guard !rows.isEmpty else { return [] }

    let summaries = try await gradeSummariesBySubmissionID(for: rows.map(\.submissionID), on: db)
    let disagreeing = gradeSourceDisagreementBySubmissionID(summaries)
    return Set(rows.filter { disagreeing[$0.submissionID] != nil }.map(\.userID))
}
