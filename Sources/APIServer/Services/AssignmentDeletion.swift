// APIServer/Services/AssignmentDeletion.swift
//
// The row half of `POST /instructor/:assignmentID/delete` (#2766).

import Fluent
import Foundation

/// Deletes one assignment's rows. The route runs `deleteRows` in one
/// transaction and removes `filePaths` only after that transaction commits.
///
/// Before #2766 each delete was its own auto-commit, and the files went first.
/// A database error after the result delete left a live assignment whose
/// submissions had no results, so its students showed as ungraded. Now a
/// failure at any step rolls every row back, and no file is gone.
enum AssignmentDeletion {
    /// What `deleteRows` removed.
    struct RemovedRows: Sendable {
        /// The number of submission rows deleted.
        let submissionCount: Int
        /// The submission and setup files that the deleted rows named. Remove
        /// them only after the transaction commits: a rollback keeps the rows
        /// that name them.
        let filePaths: [String]
        /// True when a setup row existed and was deleted. The route then also
        /// removes the setup's materialized notebook copies.
        let setupDeleted: Bool
    }

    /// Deletes the assignment, its setup, and every row that records the
    /// setup's student work or maps students to the assignment: the same
    /// tables the course purge removes (#2809). It touches no file. Call it
    /// inside a transaction.
    static func deleteRows(of assignment: APIAssignment, on db: any Database) async throws -> RemovedRows {
        let setupID = assignment.testSetupID

        // Every row that records the setup's student work, and every row
        // that maps students to this assignment, through the helper the
        // course purge also uses (#2809).
        let work = try await SetupRowDeletion.deleteStudentWork(forSetups: [setupID], on: db)
        try await SetupRowDeletion.deleteStudentMappings(forAssignments: [assignment.requireID()], on: db)

        // The setup row goes so the assignment disappears from the list.
        var filePaths = work.filePaths
        var setupDeleted = false
        if let setup = try await APITestSetup.find(setupID, on: db) {
            filePaths.append(setup.zipPath)
            if let notebookPath = setup.notebookPath, !notebookPath.isEmpty {
                filePaths.append(notebookPath)
            }
            try await setup.delete(on: db)
            setupDeleted = true
        }
        // Materials attached to the assignment become rows of their own again,
        // at the end of the assignment's section, rather than going with it:
        // the same placement as a detach from the edit form.
        let attached = try await APICourseContentItem.query(on: db)
            .filter(\.$assignmentID == assignment.requireID())
            .all()
        for item in attached {
            try await CourseContentService.attach(item, toAssignment: nil, on: db)
        }
        try await assignment.delete(on: db)
        return RemovedRows(
            submissionCount: work.submissionCount, filePaths: filePaths, setupDeleted: setupDeleted)
    }
}
