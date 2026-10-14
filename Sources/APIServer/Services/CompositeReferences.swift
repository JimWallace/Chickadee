// APIServer/Services/CompositeReferences.swift
//
// The reference render of a class composite (docs/class-composite.md,
// slice 6). "Prepare reference" grades the reference solution once for each
// slot, with that slot's inputs, and stores what each run reports. With
// `emptySlots: reference`, the projector shows a slot's render, dimmed, until
// a student's passing contribution replaces it.
//
// Each slot is one `compositeReference` submission, owned by no student, so
// every listing, aggregate and grade selection skips it (they filter on
// `student`). The worker claims these jobs behind every job a person waits on,
// with the class corpus run (`WorkerClaimEvaluation`).

import Core
import Fluent
import Foundation
import Vapor

enum CompositeReferences {

    enum PrepareError: Error, Equatable {
        /// The assignment is not a class composite.
        case notComposite
        /// The assignment has no reference solution to render.
        case noSolution
    }

    /// Queues one reference job for each slot, replacing any earlier render.
    /// Returns the number of jobs queued.
    @discardableResult
    static func prepare(
        assignment: APIAssignment, setup: APITestSetup, app: Application, on db: any Database
    )
        async throws -> Int
    {
        guard let assignmentID = assignment.id, let setupID = setup.id,
            let activity = setup.decodedManifest()?.activity, activity.kind == .classComposite,
            let spec = activity.composite
        else { throw PrepareError.notComposite }
        guard let solutionID = assignment.validationSubmissionID,
            let solution = try await APISubmission.find(solutionID, on: db),
            FileManager.default.fileExists(atPath: solution.zipPath)
        else { throw PrepareError.noSolution }
        let solutionData = try Data(contentsOf: URL(fileURLWithPath: solution.zipPath))

        // An earlier render goes, with any of its jobs still waiting: the
        // submission rows cascade to their reference rows.
        let earlier = try await APICompositeReference.query(on: db)
            .filter(\.$assignmentID == assignmentID).all().map(\.submissionID)
        if !earlier.isEmpty {
            try await APISubmission.query(on: db).filter(\.$id ~~ earlier).delete()
        }

        for slot in 0..<spec.layout.slotCount {
            let copied = try copySubmissionFile(from: solution.zipPath, into: app.submissionsDirectory)
            let submission = APISubmission(
                id: copied.id, testSetupID: setupID, zipPath: copied.path, attemptNumber: 1,
                filename: solution.filename, userID: nil, kind: APISubmission.Kind.compositeReference)
            let materialized = await materializeValidationGrading(
                submission: submission, setupID: setupID, templateNotebookData: solutionData,
                testSetupsDirectory: app.testSetupsDirectory, app: app, on: db)
            // One transaction: a runner never claims the job before its
            // reference row names the slot.
            try await db.transaction { tx in
                try await materialized.saveClaimable(on: tx)
                try await APICompositeReference(assignmentID: assignmentID, slot: slot, submissionID: copied.id)
                    .create(on: tx)
            }
        }
        return spec.layout.slotCount
    }

    /// The slot inputs of a reference job: the slot its row names.
    static func gradingInputs(
        manifest: TestProperties, submissionID: String?, on db: any Database
    ) async
        -> [String: String]?
    {
        guard let submissionID, let activity = manifest.activity, let spec = activity.composite,
            let language = AssignmentLanguage.resolve(manifest: manifest),
            let slot = try? await APICompositeReference.query(on: db)
                .filter(\.$submissionID == submissionID).first()?.slot
        else { return nil }
        return spec.inputs(forSlot: slot).mapValues(language.literal)
    }

    /// Stores what a reference job reported for its slot. A payload that is
    /// not the assignment's shape is discarded with a log line.
    static func record(
        submission: APISubmission, collection: TestOutcomeCollection, on db: any Database
    )
        async throws
    {
        guard submission.kind == APISubmission.Kind.compositeReference, let submissionID = submission.id,
            let row = try await APICompositeReference.query(on: db)
                .filter(\.$submissionID == submissionID).first(),
            let spec = try await APITestSetup.find(submission.testSetupID, on: db)?
                .decodedManifest()?.activity?.composite
        else { return }
        let outcome = collection.outcomes.first(where: { $0.composite != nil })
        guard let outcome, let contribution = outcome.composite,
            CompositeContributions.isValid(contribution, for: spec.contribution)
        else {
            db.logger.warning("composite: reference job \(submissionID) reported no valid render")
            row.data = nil
            row.passed = false
            try await row.save(on: db)
            return
        }
        row.data = contribution.data
        row.passed = outcome.status == .pass
        try await row.save(on: db)
    }

    /// How many slots have a passing render, out of how many slots have a
    /// reference row. Nil when no render was ever prepared.
    static func progress(assignmentID: UUID, on db: any Database) async throws -> (ready: Int, total: Int)? {
        let rows = try await APICompositeReference.query(on: db).filter(\.$assignmentID == assignmentID).all()
        guard !rows.isEmpty else { return nil }
        return (rows.filter { $0.passed && $0.data != nil }.count, rows.count)
    }
}
