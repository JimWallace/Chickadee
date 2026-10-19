// APIServer/Services/CompositeContributions.swift
//
// Stores what a student's graded submission added to a class composite
// (docs/class-composite.md, slice 4). `ResultIngestEffects.apply` calls this
// for both ingest paths, the worker report and the browser result, so the two
// cannot drift.
//
// The server checks every payload again here. A browser-posted outcome is not
// trusted, and a contribution whose shape is not the assignment's shape cannot
// fill its slot. A bad payload is discarded with a log line. The grade never
// changes: the composite is a display.
//
// The stored result keeps its copy of the contribution too. It is at most
// about 87 KB of base64 for each outcome, well inside the 6 MB result budget,
// and this table, not the result, is what the composite view reads.

import Core
import Fluent
import Foundation
import Vapor

enum CompositeContributions {

    /// What `record` did with a submission's contribution.
    enum Outcome: Equatable {
        /// Not a class composite, no contribution reported, or not a student's.
        case notApplicable
        /// The payload is not the assignment's shape, or not valid base64 of
        /// the right length. Nothing was stored.
        case discarded
        /// The student has no dealt slot. Grading deals one first, so this
        /// happens only when that deal failed.
        case noSlot
        /// A newer submission's contribution is already stored.
        case superseded
        /// Stored. A passing contribution also covered its slot.
        case stored(slot: Int, passed: Bool)
    }

    /// Stores the contribution in `collection` for the student who owns
    /// `submission`, and records the slot as covered when its test passed.
    ///
    /// The contribution is the first one in suite order. A test script for a
    /// composite reports one; a second is ignored.
    ///
    /// For an activity that runs per group, the contribution fills the
    /// student's slot in the group whose pool dealt it, whenever it is graded
    /// (docs/lab-groups.md, slice 4), and a passing tile covers the slot in
    /// that lab's coverage (slice 5b).
    @discardableResult
    static func record(
        submission: APISubmission, collection: TestOutcomeCollection, on db: any Database
    ) async throws -> Outcome {
        guard let userID = submission.userID, let submissionID = submission.id,
            let outcome = collection.outcomes.first(where: { $0.composite != nil }),
            let contribution = outcome.composite,
            let setup = try await APITestSetup.find(submission.testSetupID, on: db),
            let activity = setup.decodedManifest()?.activity, activity.kind == .classComposite,
            let spec = activity.composite,
            let assignmentID = try await APIAssignment.query(on: db)
                .filter(\.$testSetupID == submission.testSetupID).first()?.id,
            // Staff render the reference slot and hold no dealt slot.
            try await courseRole(of: userID, inCourse: setup.courseID, db: db) == .student
        else { return .notApplicable }

        guard isValid(contribution, for: spec.contribution) else {
            db.logger.warning("composite: discarded an invalid contribution from submission \(submissionID)")
            return .discarded
        }
        guard let (pool, slot) = try await CompositePool.dealtSlot(assignmentID: assignmentID, userID: userID, on: db)
        else {
            db.logger.warning("composite: submission \(submissionID) has no dealt slot")
            return .noSlot
        }

        let passed = outcome.status == .pass
        let row = APICompositeContribution(
            assignmentID: assignmentID, userID: userID, slot: slot, submissionID: submissionID,
            submittedAt: submission.submittedAt ?? .distantPast, contribution: contribution, passed: passed)
        row.groupID = pool.groupID
        guard try await upsert(row, on: db) else { return .superseded }

        if passed {
            try await cover(
                slot: slot, in: pool, testSetupID: submission.testSetupID, userID: userID,
                submissionID: submissionID, on: db)
        }
        return .stored(slot: slot, passed: passed)
    }

    /// Covers the slot's item for the student, in the class's coverage or in
    /// the coverage of the lab whose pool dealt it (docs/lab-groups.md, slice
    /// 5b). The first to cover a slot keeps it, as for every item, but the
    /// holder's own tile takes the slot back from a spare (slice 6b): the
    /// spare filled a hole the holder had left.
    private static func cover(
        slot: Int, in pool: CompositePool, testSetupID: String, userID: UUID, submissionID: String,
        on db: any Database
    ) async throws {
        let item = CompositeSpec.coverageItem(forSlot: slot)
        let spareJobs = try await pool.spares(on: db).filter { $0.slot == slot }.map(\.submissionID)
        guard let groupID = pool.groupID else {
            try await APIClassItemCoverage(
                testSetupID: testSetupID, item: item, userID: userID, submissionID: submissionID
            ).createIgnoringConflict(on: db)
            guard !spareJobs.isEmpty else { return }
            try await APIClassItemCoverage.query(on: db)
                .filter(\.$testSetupID == testSetupID).filter(\.$item == item)
                .filter(\.$submissionID ~~ spareJobs)
                .set(\.$userID, to: userID).set(\.$submissionID, to: submissionID)
                .update()
            return
        }
        try await recordLabItemCoverage(
            testSetupID: testSetupID, groupID: groupID, items: [item], userID: userID, submissionID: submissionID,
            on: db)
        guard !spareJobs.isEmpty else { return }
        try await APIGroupClassItemCoverage.query(on: db)
            .filter(\.$testSetupID == testSetupID).filter(\.$groupID == groupID).filter(\.$item == item)
            .filter(\.$submissionID ~~ spareJobs)
            .set(\.$userID, to: userID).set(\.$submissionID, to: submissionID)
            .update()
    }

    /// Whether a contribution can fill a slot of this composite: the shape is
    /// the assignment's, and `data` is standard padded base64 of exactly the
    /// right length, at most `CompositeContribution.maxPayloadBytes`.
    static func isValid(_ contribution: CompositeContribution, for shape: CompositeContributionShape) -> Bool {
        guard contribution.width == shape.width, contribution.height == shape.height,
            contribution.frames == shape.frames, contribution.format == shape.format
        else { return false }
        // The shape is bounded at save, so this cannot overflow. Standard
        // padded base64 of n bytes is exactly 4 × ceil(n / 3) characters, so
        // the length check refuses unpadded text before anything is decoded.
        let byteCount = contribution.expectedByteCount
        guard byteCount <= CompositeContribution.maxPayloadBytes,
            contribution.data.utf8.count == (byteCount + 2) / 3 * 4,
            let bytes = Data(base64Encoded: contribution.data)
        else { return false }
        return bytes.count == byteCount
    }

    // MARK: - Private

    /// Inserts `row` or replaces the student's stored row. Returns false when the stored
    /// row came from a newer submission.
    ///
    /// Safe under a race. The replace is one conditional UPDATE, so of two
    /// results for one student the newer submission is the one left stored,
    /// in either order. A loser of the insert reads the winner's row and
    /// tries the update. No insert runs inside a transaction: on Postgres a
    /// failed insert aborts the transaction.
    private static func upsert(_ row: APICompositeContribution, on db: any Database) async throws -> Bool {
        func studentRow() -> QueryBuilder<APICompositeContribution> {
            APICompositeContribution.query(on: db)
                .filter(\.$assignmentID == row.assignmentID)
                .filter(\.$userID == row.userID)
        }
        for _ in 0..<2 {
            if try await studentRow().count() > 0 {
                try await studentRow()
                    .filter(\.$submittedAt <= row.submittedAt)
                    .set(\.$groupID, to: row.groupID)
                    .set(\.$slot, to: row.slot)
                    .set(\.$submissionID, to: row.submissionID)
                    .set(\.$submittedAt, to: row.submittedAt)
                    .set(\.$width, to: row.width)
                    .set(\.$height, to: row.height)
                    .set(\.$frames, to: row.frames)
                    .set(\.$format, to: row.format)
                    .set(\.$data, to: row.data)
                    .set(\.$passed, to: row.passed)
                    .set(\.$updatedAt, to: Date())
                    .update()
                return try await studentRow().first()?.submissionID == row.submissionID
            }
            do {
                try await row.create(on: db)
                return true
            } catch let error where isInsertConflict(error) {
                continue
            }
        }
        return false
    }
}
