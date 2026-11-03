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

        let assignmentIDs = try await APIAssignment.query(on: db)
            .filter(\.$courseID == courseID).all().compactMap(\.id)

        // 2. Submissions, results, variants, the class, composite and
        // dataset-deal rows and the awards: the same set the assignment
        // delete removes (#2809).
        let shared = try await SetupRowDeletion.deleteRows(
            forTestSetups: setupIDs, assignmentIDs: assignmentIDs, on: db)
        filePaths += shared.filePaths

        // The course's own awards name the student, keyed by the course
        // with no foreign key (docs/achievement-rewards.md, S3).
        try await AchievementAwardStore.deleteCourseAwards(forCourse: courseID, on: db)

        // 3. Assignments.
        try await APIAssignment.query(on: db)
            .filter(\.$courseID == courseID).delete()

        // 4. Collect the test setup file paths, then delete the setup records.
        for setup in setups {
            guard let sid = setup.id else { continue }
            filePaths.append(setupsDirectory + "\(sid).zip")
            filePaths.append(setupsDirectory + "\(sid).ipynb")
        }
        try await APITestSetup.query(on: db)
            .filter(\.$courseID == courseID).delete()

        // 5. Enrollments then course record.
        try await APICourseEnrollment.query(on: db)
            .filter(\.$course.$id == courseID).delete()
        try await course.delete(on: db)
        return PurgedRows(submissionCount: shared.submissionCount, filePaths: filePaths)
    }
}
