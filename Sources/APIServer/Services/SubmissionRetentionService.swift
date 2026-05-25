// APIServer/Services/SubmissionRetentionService.swift
//
// Submission-retention policy: student submissions are kept for one year
// (the SUBMISSION_RETENTION_DAYS window) after the END OF TERM, then purged.
// Chickadee has no term/semester concept, so "end of term" is signalled by
// archiving the course — the retention clock starts at `APICourse.archivedAt`.
//
// This is FIPPA / UWaterloo TL55 retention: assignments (submissions) are
// personal information that must be retained for one year after term end and
// then disposed of. Grades themselves are not kept here long-term — they flow
// to LEARN (D2L) for TL60 retention via BrightSpaceGradeSyncService.
//
// The policy is deliberately *report-first*: this service surfaces what is
// (and will be) purgeable and performs a purge only when an admin explicitly
// triggers it from /admin/retention. There is no timer and nothing deletes
// student work automatically — mirroring how cautiously a privacy-impacting
// deletion should be rolled out.

import Core
import Fluent
import Foundation

enum SubmissionRetentionService {

    /// Retention status for one archived course, used to render the report.
    struct CourseRetentionStatus: Sendable {
        /// When the course was archived (the retention-clock anchor).
        let archivedAt: Date
        /// `archivedAt + retentionDays` — when submissions become purgeable.
        let purgeEligibleAt: Date
        /// True once `now >= purgeEligibleAt`.
        let isPurgeable: Bool
        /// How many submissions would be removed by a purge.
        let submissionCount: Int
    }

    /// The date an archived course's submissions become eligible for purging.
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

        let submissions = try await APISubmission.query(on: db)
            .filter(\.$testSetupID ~~ setupIDs)
            .field(\.$testSetupID)
            .all()
        var counts: [UUID: Int] = [:]
        for submission in submissions {
            if let courseID = courseBySetup[submission.testSetupID] {
                counts[courseID, default: 0] += 1
            }
        }
        return counts
    }

    /// Deletes every submission belonging to `courseID`'s test setups: the
    /// submission rows, their `results` rows, and the on-disk submission
    /// artifacts. `submission_diagnostics` rows cascade away via their
    /// `onDelete: .cascade` FK on `submission_id`.
    ///
    /// Deliberately scoped to *submission data only* — the course, its
    /// assignments, test setups, enrollments, and user accounts are left
    /// intact (a user may have submissions in other, still-active courses).
    /// Mirrors the submission-deletion portion of `deleteCourse`.
    ///
    /// Returns the number of submission rows removed.
    @discardableResult
    static func purgeSubmissions(
        forCourseID courseID: UUID,
        on db: Database
    ) async throws -> Int {
        try await db.transaction { tx -> Int in
            let setups = try await APITestSetup.query(on: tx)
                .filter(\.$courseID == courseID)
                .all()
            let setupIDs = setups.compactMap { $0.id }
            guard !setupIDs.isEmpty else { return 0 }

            let submissions = try await APISubmission.query(on: tx)
                .filter(\.$testSetupID ~~ setupIDs)
                .all()
            guard !submissions.isEmpty else { return 0 }

            let submissionIDs = submissions.compactMap { $0.id }
            if !submissionIDs.isEmpty {
                try await APIResult.query(on: tx)
                    .filter(\.$submissionID ~~ submissionIDs)
                    .delete()
            }

            for submission in submissions {
                try? FileManager.default.removeItem(atPath: submission.zipPath)
            }

            try await APISubmission.query(on: tx)
                .filter(\.$testSetupID ~~ setupIDs)
                .delete()

            return submissions.count
        }
    }
}
