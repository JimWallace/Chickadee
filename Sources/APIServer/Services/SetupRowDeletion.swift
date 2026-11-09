// APIServer/Services/SetupRowDeletion.swift
//
// The rows that belong to a test setup's student work and to an assignment,
// deleted the same way by the assignment delete and the course purge (#2809).

import Fluent
import Foundation

/// Deletes the rows that record student work for a set of test setups and
/// assignments. `AssignmentDeletion` and `CoursePurge` both call it inside
/// their transaction, so the two deletes remove the same tables.
///
/// Before #2809 each delete kept its own list. The assignment delete removed
/// fewer tables, so it left rows that name students and their submission
/// files behind. Neither function here touches a file: the caller removes the
/// returned paths only after its transaction commits (#2766).
enum SetupRowDeletion {
    /// What `deleteStudentWork` removed.
    struct RemovedWork: Sendable {
        /// The number of submission rows deleted.
        let submissionCount: Int
        /// The submission files that the deleted rows named. Remove them only
        /// after the transaction commits.
        let filePaths: [String]
    }

    /// Deletes every row keyed by these setups that records student work:
    /// submissions with their results, validation variants, class coverage
    /// runs, item coverage, awards and class-goal data. It does not delete
    /// the setup rows. Call it inside a transaction.
    static func deleteStudentWork(forSetups setupIDs: [String], on db: any Database) async throws -> RemovedWork {
        guard !setupIDs.isEmpty else { return RemovedWork(submissionCount: 0, filePaths: []) }

        let submissions = try await APISubmission.query(on: db)
            .filter(\.$testSetupID ~~ setupIDs).all()
        let submissionIDs = submissions.compactMap(\.id)
        // Chunked: one IN list of every submission in a course passes the
        // driver bind limit for a large course (#2764).
        for chunk in chunkedForInFilter(submissionIDs) {
            try await APIResult.query(on: db)
                .filter(\.$submissionID ~~ chunk).delete()
        }

        // Variant batches go before their submissions: their FK is
        // `.setNull`, so the other order leaves unlinked rows for setups that
        // no longer exist.
        try await ValidationVariant.query(on: db)
            .filter(\.$testSetupID ~~ setupIDs).delete()
        // The corpus runs go with the submissions they name. They are the one
        // class-level table holding WHO contributed rather than only what was
        // graded, which is why deletion reaches them explicitly
        // (docs/collaborative-class-assignments.md, Phase 4).
        try await APIClassCoverageRun.query(on: db)
            .filter(\.$testSetupID ~~ setupIDs).delete()
        // The per-item coverage union records who covered each item first.
        // Keyed by setup with no foreign key, so nothing else removes it.
        try await APIClassItemCoverage.query(on: db)
            .filter(\.$testSetupID ~~ setupIDs).delete()
        // The award ledger names the student and the work that earned the
        // award, keyed by setup with no foreign key.
        try await AchievementAwardStore.deleteAwards(forTestSetups: setupIDs, on: db)
        // A class goal's snapshots, the class's and each lab's, and each
        // lab's item coverage. Keyed by setup with no foreign key, so nothing
        // else removes them.
        try await LabGoalGroups.deleteClassGoalData(forTestSetups: setupIDs, on: db)
        try await deleteActivityRows(forSetups: setupIDs, on: db)
        try await APISubmission.query(on: db)
            .filter(\.$testSetupID ~~ setupIDs).delete()

        return RemovedWork(submissionCount: submissions.count, filePaths: submissions.map(\.zipPath))
    }

    /// Deletes the class-activity and grade-push rows keyed by setup with no
    /// foreign key: badges, leaderboards, king-of-the-hill matches and
    /// champions, round-robin standings, tournaments (their matches go by
    /// cascade) and the LTI push queue, the class's and each lab group's. Each
    /// names a student and a submission, so nothing may outlive the setup.
    /// `StudentWorkDeletionCoverageTests` finds every such table from the
    /// catalog, so a new one fails there until it is deleted here.
    private static func deleteActivityRows(forSetups setupIDs: [String], on db: any Database) async throws {
        try await APIClassAchievement.query(on: db).filter(\.$testSetupID ~~ setupIDs).delete()
        try await APILeaderboardEntry.query(on: db).filter(\.$testSetupID ~~ setupIDs).delete()
        try await APIGroupLeaderboardEntry.query(on: db).filter(\.$testSetupID ~~ setupIDs).delete()
        try await APIMatchResult.query(on: db).filter(\.$testSetupID ~~ setupIDs).delete()
        try await APIActivityChampion.query(on: db).filter(\.$testSetupID ~~ setupIDs).delete()
        try await APIGroupActivityChampion.query(on: db).filter(\.$testSetupID ~~ setupIDs).delete()
        try await APIActivityStanding.query(on: db).filter(\.$testSetupID ~~ setupIDs).delete()
        try await APITournamentRun.query(on: db).filter(\.$testSetupID ~~ setupIDs).delete()
        try await APILTIGradeSync.query(on: db).filter(\.$testSetupID ~~ setupIDs).delete()
    }

    /// Deletes the per-assignment rows that map students to their work: a
    /// class composite's contributions, slots, reference renders and spares,
    /// and the deal numbers that map students to partition datasets. They go
    /// explicitly, not only by the cascade. It does not delete the assignment
    /// rows. Call it inside a transaction.
    static func deleteStudentMappings(forAssignments assignmentIDs: [UUID], on db: any Database) async throws {
        guard !assignmentIDs.isEmpty else { return }
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
}
