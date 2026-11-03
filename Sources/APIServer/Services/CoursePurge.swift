// APIServer/Services/CoursePurge.swift
//
// The row half of `POST /admin/courses/:courseID/delete` (#2766).

import Fluent
import Foundation

/// Deletes one course and every row that belongs to it. The route runs
/// `deleteRows` in one transaction and removes `filePaths` only after that
/// transaction commits.
///
/// Before #2766 the zip files went inside the transaction. A later step that
/// threw rolled the rows back, but their files were already gone.
enum CoursePurge {
    /// What `deleteRows` removed.
    struct PurgedRows: Sendable {
        /// The number of submission rows deleted.
        let submissionCount: Int
        /// The submission and test setup files that the deleted rows named.
        /// Remove them only after the transaction commits.
        let filePaths: [String]
    }

    /// Deletes the course's setups, submissions, results, assignments,
    /// enrollments and the course row. It touches no file. Call it inside a
    /// transaction.
    static func deleteRows(
        of course: APICourse, setupsDirectory: String, on db: any Database
    ) async throws -> PurgedRows {
        let courseID = try course.requireID()
        var filePaths: [String] = []

        // 1. Test setups for this course.
        let setups = try await APITestSetup.query(on: db)
            .filter(\.$courseID == courseID).all()
        let setupIDs = setups.compactMap(\.id)

        // 2. Submissions → results → delete.
        let submissions = try await APISubmission.query(on: db)
            .filter(\.$testSetupID ~~ setupIDs).all()
        let subIDs = submissions.compactMap(\.id)
        if !subIDs.isEmpty {
            try await APIResult.query(on: db)
                .filter(\.$submissionID ~~ subIDs).delete()
        }

        // 3. Collect the submission zip paths, then delete the submission
        // records (variant batches first — their FK is `.setNull`, so the
        // other order leaves unlinked rows for setups that no longer exist).
        filePaths += submissions.map(\.zipPath)
        if !setupIDs.isEmpty {
            try await ValidationVariant.query(on: db)
                .filter(\.$testSetupID ~~ setupIDs).delete()
            // The corpus runs go with the submissions they name. They are
            // the one class-level table holding WHO contributed rather than
            // only what was graded, which is why deletion reaches them
            // explicitly (docs/collaborative-class-assignments.md, Phase 4).
            try await APIClassCoverageRun.query(on: db)
                .filter(\.$testSetupID ~~ setupIDs).delete()
            // The per-item coverage union records who covered each item
            // first. Keyed by setup with no foreign key, so nothing else
            // removes it.
            try await APIClassItemCoverage.query(on: db)
                .filter(\.$testSetupID ~~ setupIDs).delete()
            // The award ledger names the student and the work that earned
            // the award, keyed by setup with no foreign key.
            try await AchievementAwardStore.deleteAwards(forTestSetups: setupIDs, on: db)
            // A class goal's snapshots, the class's and each lab's, and
            // each lab's item coverage. Keyed by setup with no foreign key,
            // so nothing else removes them.
            try await LabGoalGroups.deleteClassGoalData(forTestSetups: setupIDs, on: db)
            try await APISubmission.query(on: db)
                .filter(\.$testSetupID ~~ setupIDs).delete()
        }
        // The course's own awards name the student, keyed by the course
        // with no foreign key (docs/achievement-rewards.md, S3).
        try await AchievementAwardStore.deleteCourseAwards(forCourse: courseID, on: db)

        // 4. Assignments. A class composite's slots and contributions map
        // students to their work, so they go explicitly, not only by the
        // cascade. Its reference renders and spares go with them, and so
        // do the deal numbers that map students to partition datasets.
        let assignmentIDs = try await APIAssignment.query(on: db)
            .filter(\.$courseID == courseID).all().compactMap(\.id)
        if !assignmentIDs.isEmpty {
            try await APICompositeContribution.query(on: db)
                .filter(\.$assignmentID ~~ assignmentIDs).delete()
            try await APICompositeSlot.query(on: db)
                .filter(\.$assignmentID ~~ assignmentIDs).delete()
            try await APIGroupCompositeSlot.query(on: db)
                .filter(\.$assignmentID ~~ assignmentIDs).delete()
            try await APICompositeReference.query(on: db)
                .filter(\.$assignmentID ~~ assignmentIDs).delete()
            try await APICompositeSpare.query(on: db)
                .filter(\.$assignmentID ~~ assignmentIDs).delete()
            try await APIGroupCompositeSpare.query(on: db)
                .filter(\.$assignmentID ~~ assignmentIDs).delete()
            try await APIDatasetDeal.query(on: db)
                .filter(\.$assignmentID ~~ assignmentIDs).delete()
        }
        try await APIAssignment.query(on: db)
            .filter(\.$courseID == courseID).delete()

        // 5. Collect the test setup file paths, then delete the setup records.
        for setup in setups {
            guard let sid = setup.id else { continue }
            filePaths.append(setupsDirectory + "\(sid).zip")
            filePaths.append(setupsDirectory + "\(sid).ipynb")
        }
        try await APITestSetup.query(on: db)
            .filter(\.$courseID == courseID).delete()

        // 6. Enrollments then course record.
        try await APICourseEnrollment.query(on: db)
            .filter(\.$course.$id == courseID).delete()
        try await course.delete(on: db)
        return PurgedRows(submissionCount: submissions.count, filePaths: filePaths)
    }
}
