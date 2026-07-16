// APIServer/Services/SubmissionRetentionService.swift
//
// Submission-retention policy: a course's data is kept for one year
// (the SUBMISSION_RETENTION_DAYS window) after the END OF TERM, then becomes
// eligible for permanent deletion. Chickadee has no term/semester concept, so
// "end of term" is signalled by archiving the course — the retention clock
// starts at `APICourse.archivedAt`.
//
// This is FIPPA / UWaterloo TL55 retention: assignments (submissions) are
// personal information that must be retained for one year after term end and
// then disposed of. Grades themselves are not kept here long-term — they flow
// to LEARN (D2L) for TL60 retention via BrightSpaceGradeSyncService.
//
// The policy is deliberately *report-first*: this service only computes the
// eligibility date and counts submissions for the /admin/retention report.
// The actual destructive action is the admin-triggered `deleteCourse`
// (gated on `purgeEligibleDate`). There is no timer and nothing deletes
// automatically — mirroring how cautiously a privacy-impacting deletion
// should be rolled out.

import Core
import Fluent
import Foundation
import SQLKit

enum SubmissionRetentionService {

    /// The date an archived course becomes eligible for permanent deletion
    /// (`archivedAt + retentionDays`). Named historically for the retention
    /// "purge" window; `AdminRoutes.deleteCourse` gates on this.
    static func purgeEligibleDate(archivedAt: Date, retentionDays: Int) -> Date {
        archivedAt.addingTimeInterval(TimeInterval(retentionDays) * 86_400)
    }

    /// Counts submissions per course (joined through each course's test
    /// setups) for the given course IDs. Two queries total, independent of
    /// how many courses are passed in. Courses with no submissions are absent
    /// from the result (callers should default to 0).
    static func submissionCountsByCourse(
        courseIDs: [UUID],
        on db: Database
    ) async throws -> [UUID: Int] {
        guard !courseIDs.isEmpty else { return [:] }

        let setups = try await APITestSetup.query(on: db)
            .filter(\.$courseID ~~ courseIDs)
            .field(\.$id)
            .field(\.$courseID)
            .all()
        var courseBySetup: [String: UUID] = [:]
        for setup in setups {
            if let id = setup.id { courseBySetup[id] = setup.courseID }
        }
        let setupIDs = Array(courseBySetup.keys)
        guard !setupIDs.isEmpty else { return [:] }

        // Grouped COUNT(*) instead of materializing one row per submission —
        // this backs /admin/retention across ALL archived courses at once,
        // and submissions is the largest unbounded-growth table (2026-07
        // audit; same pattern as loadUniqueSubmittersBySetup).
        var counts: [UUID: Int] = [:]
        if let sql = db as? SQLDatabase {
            struct SetupCountRow: Decodable {
                let testSetupID: String
                let total: Int
                enum CodingKeys: String, CodingKey {
                    case testSetupID = "test_setup_id"
                    case total
                }
            }
            let rows = try await sql.select()
                .column("test_setup_id")
                .column(SQLFunction("COUNT", args: SQLLiteral.all), as: "total")
                .from("submissions")
                .where("test_setup_id", .in, setupIDs)
                .groupBy("test_setup_id")
                .all(decoding: SetupCountRow.self)
            for row in rows {
                if let courseID = courseBySetup[row.testSetupID] {
                    counts[courseID, default: 0] += row.total
                }
            }
            return counts
        }

        // Non-SQL fallback (not hit by the sqlite/postgres drivers in use).
        let submissions = try await APISubmission.query(on: db)
            .filter(\.$testSetupID ~~ setupIDs)
            .field(\.$testSetupID)
            .all()
        for submission in submissions {
            if let courseID = courseBySetup[submission.testSetupID] {
                counts[courseID, default: 0] += 1
            }
        }
        return counts
    }
}
