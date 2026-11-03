// APIServer/Services/SetupRowDeletion.swift
//
// The rows that the assignment delete and the course purge share (#2809).

import Fluent
import Foundation

/// Deletes the rows that belong to a set of test setups and their assignments:
/// the submissions with their results and validation variants, the class
/// coverage and class-goal rows, the awards, and the composite and dataset-deal
/// rows. `AssignmentDeletion` and `CoursePurge` both call it, so the two
/// deletes cannot drift apart again.
///
/// It deletes neither the setup rows nor the assignment rows: each caller
/// selects those its own way. It touches no file. Call it inside a
/// transaction, and remove `filePaths` only after that transaction commits.
enum SetupRowDeletion {
    /// What `deleteRows` removed.
    struct RemovedRows: Sendable {
        /// The number of submission rows deleted.
        let submissionCount: Int
        /// The submission files that the deleted rows named.
        let filePaths: [String]
    }

    static func deleteRows(
        forTestSetups setupIDs: [String], assignmentIDs: [UUID], on db: any Database
    ) async throws -> RemovedRows {
        var submissions: [APISubmission] = []
        if !setupIDs.isEmpty {
            submissions = try await APISubmission.query(on: db)
                .filter(\.$testSetupID ~~ setupIDs).all()
            // Chunked: one IN list of every submission in a course passes the
            // driver bind limit for a large course (#2764).
            for chunk in chunkedForInFilter(submissions.compactMap(\.id)) {
                try await APIResult.query(on: db)
                    .filter(\.$submissionID ~~ chunk).delete()
            }
            // Variant rows must go before their submissions: the FK is
            // `.setNull`, so the other order leaves the batch as unlinked rows
            // for a setup that no longer exists.
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

        // A class composite's slots and contributions map students to their
        // work, so they go explicitly, not only by the cascade. Its reference
        // renders and spares go with them, and so do the deal numbers that map
        // students to partition datasets.
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
        return RemovedRows(submissionCount: submissions.count, filePaths: submissions.map(\.zipPath))
    }
}
