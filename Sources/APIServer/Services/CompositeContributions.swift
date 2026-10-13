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
        guard
            let slot = try await APICompositeSlot.query(on: db)
                .filter(\.$assignmentID == assignmentID)
                .filter(\.$userID == userID)
                .first()?.slot
        else {
            db.logger.warning("composite: submission \(submissionID) has no dealt slot")
            return .noSlot
        }

        let passed = outcome.status == .pass
        let stored = try await upsert(
            assignmentID: assignmentID, userID: userID, slot: slot, submissionID: submissionID,
            submittedAt: submission.submittedAt ?? Date(), contribution: contribution, passed: passed, on: db)
        guard stored else { return .superseded }

        if passed {
            // First to cover the slot keeps it, as for every coverage item.
            try await APIClassItemCoverage(
                testSetupID: submission.testSetupID, item: CompositeSpec.coverageItem(forSlot: slot),
                userID: userID, submissionID: submissionID
            ).createIgnoringConflict(on: db)
        }
        return .stored(slot: slot, passed: passed)
    }

    /// Whether a contribution can fill a slot of this composite: the shape is
    /// the assignment's, and `data` is valid base64 of exactly the right
    /// length, at most `CompositeContribution.maxPayloadBytes`.
    static func isValid(_ contribution: CompositeContribution, for shape: CompositeContributionShape) -> Bool {
        guard contribution.width == shape.width, contribution.height == shape.height,
            contribution.frames == shape.frames, contribution.format == shape.format,
            let bytes = Data(base64Encoded: contribution.data)
        else { return false }
        return bytes.count == contribution.expectedByteCount
            && bytes.count <= CompositeContribution.maxPayloadBytes
    }

    // MARK: - Private

    /// Inserts or replaces the student's row. Returns false when the stored
    /// row came from a newer submission. No insert runs inside a transaction:
    /// a second result for the same student can race this one, and the loser
    /// of the insert reads the winner's row and compares again.
    private static func upsert(
        assignmentID: UUID, userID: UUID, slot: Int, submissionID: String, submittedAt: Date,
        contribution: CompositeContribution, passed: Bool, on db: any Database
    ) async throws -> Bool {
        for _ in 0..<2 {
            if let existing = try await APICompositeContribution.query(on: db)
                .filter(\.$assignmentID == assignmentID)
                .filter(\.$userID == userID)
                .first()
            {
                guard submittedAt >= existing.submittedAt else { return false }
                existing.replace(
                    slot: slot, submissionID: submissionID, submittedAt: submittedAt,
                    contribution: contribution, passed: passed)
                try await existing.save(on: db)
                return true
            }
            do {
                try await APICompositeContribution(
                    assignmentID: assignmentID, userID: userID, slot: slot, submissionID: submissionID,
                    submittedAt: submittedAt, contribution: contribution, passed: passed
                ).create(on: db)
                return true
            } catch let error where isInsertConflict(error) {
                continue
            }
        }
        return false
    }
}
