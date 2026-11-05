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

        // 2. Every row that records student work in those setups, through
        // the helper the assignment delete also uses (#2809). Collect the
        // submission file paths for removal after commit.
        let work = try await SetupRowDeletion.deleteStudentWork(forSetups: setupIDs, on: db)
        filePaths += work.filePaths

        // The course's own awards name the student, keyed by the course
        // with no foreign key (docs/achievement-rewards.md, S3).
        try await AchievementAwardStore.deleteCourseAwards(forCourse: courseID, on: db)

        // 3. Assignments, after the rows that map students to their work.
        let assignmentIDs = try await APIAssignment.query(on: db)
            .filter(\.$courseID == courseID).all().compactMap(\.id)
        try await SetupRowDeletion.deleteStudentMappings(forAssignments: assignmentIDs, on: db)
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
        return PurgedRows(submissionCount: work.submissionCount, filePaths: filePaths)
    }
}
