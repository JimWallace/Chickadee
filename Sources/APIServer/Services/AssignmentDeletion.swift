// APIServer/Services/AssignmentDeletion.swift
//
// The row half of `POST /instructor/:assignmentID/delete` (#2766).

import Fluent
import Foundation

/// Deletes one assignment's rows. The route runs `deleteRows` in one
/// transaction and removes `filePaths` only after that transaction commits.
///
/// Before #2766 each delete was its own auto-commit, and the files went first.
/// A `SQLITE_BUSY` after the result delete left a live assignment whose
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

    /// Deletes the assignment, its setup, and every row that `SetupRowDeletion`
    /// removes for them. It touches no file. Call it inside a transaction.
    static func deleteRows(of assignment: APIAssignment, on db: any Database) async throws -> RemovedRows {
        let setupID = assignment.testSetupID

        // The submissions, their results and variants, the class and
        // composite rows and the awards: the same set the course purge
        // removes (#2809). Several of these name the contributing student.
        let shared = try await SetupRowDeletion.deleteRows(
            forTestSetups: [setupID], assignmentIDs: [try assignment.requireID()], on: db)

        // The setup row goes so the assignment disappears from the list.
        var filePaths = shared.filePaths
        var setupDeleted = false
        if let setup = try await APITestSetup.find(setupID, on: db) {
            filePaths.append(setup.zipPath)
            if let notebookPath = setup.notebookPath, !notebookPath.isEmpty {
                filePaths.append(notebookPath)
            }
            try await setup.delete(on: db)
            setupDeleted = true
        }
        try await assignment.delete(on: db)
        return RemovedRows(
            submissionCount: shared.submissionCount, filePaths: filePaths, setupDeleted: setupDeleted)
    }
}
