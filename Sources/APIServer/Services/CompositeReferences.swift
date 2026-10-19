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
        /// Another "Prepare reference" for the assignment saved first.
        case concurrentPrepare
    }

    /// Queues one reference job for each slot, replacing any earlier render.
    /// Returns the number of jobs queued.
    ///
    /// The solution files are written first. Then one transaction removes the
    /// earlier render and saves every job with its row, so a runner never
    /// claims a job before its row names the slot, and a failure leaves the
    /// earlier render as it was.
    @discardableResult
    static func prepare(
        assignment: APIAssignment, setup: APITestSetup, app: Application, on db: any Database
    ) async throws -> Int {
        guard let assignmentID = assignment.id, let setupID = setup.id,
            let activity = setup.decodedManifest()?.activity, activity.kind == .classComposite,
            let spec = activity.composite
        else { throw PrepareError.notComposite }
        guard let solutionID = assignment.validationSubmissionID,
            let solution = try await APISubmission.find(solutionID, on: db),
            FileManager.default.fileExists(atPath: solution.zipPath)
        else { throw PrepareError.noSolution }
        let solutionData = try Data(contentsOf: URL(fileURLWithPath: solution.zipPath))

        var jobs: [(id: String, job: MaterializedValidationSubmission)] = []
        var written: [String] = []
        let removed: [String]
        do {
            for _ in 0..<spec.layout.slotCount {
                let copied = try copySubmissionFile(from: solution.zipPath, into: app.submissionsDirectory)
                written += [copied.path, copied.path + ".grading"]
                let submission = APISubmission(
                    id: copied.id, testSetupID: setupID, zipPath: copied.path, attemptNumber: 1,
                    filename: solution.filename, userID: nil, kind: APISubmission.Kind.compositeReference)
                // The slot inputs join at claim time (`gradingInputs`), so one
                // materialization serves every slot.
                if let first = jobs.first {
                    jobs.append((copied.id, try first.job.cloned(as: submission)))
                } else {
                    let job = await materializeValidationGrading(
                        submission: submission, setupID: setupID, templateNotebookData: solutionData,
                        testSetupsDirectory: app.testSetupsDirectory, app: app, on: db)
                    jobs.append((copied.id, job))
                }
            }
            let queued = jobs
            removed = try await db.transaction { tx in
                let removed = try await removeEarlier(assignmentID: assignmentID, testSetupID: setupID, on: tx)
                for (slot, entry) in queued.enumerated() {
                    try await entry.job.saveClaimable(on: tx)
                    try await APICompositeReference(assignmentID: assignmentID, slot: slot, submissionID: entry.id)
                        .create(on: tx)
                }
                return removed
            }
        } catch {
            for path in written { try? FileManager.default.removeItem(atPath: path) }
            if let error = error as? any DatabaseError, error.isConstraintFailure {
                throw PrepareError.concurrentPrepare
            }
            throw error
        }
        for path in removed { try? FileManager.default.removeItem(atPath: path) }
        return spec.layout.slotCount
    }

    /// Removes the earlier render: every reference row of the assignment, and
    /// every reference job that no runner holds. A job that a runner holds
    /// finishes, finds no row, and records nothing. Returns the files of the
    /// removed jobs, to delete after the commit.
    private static func removeEarlier(
        assignmentID: UUID, testSetupID: String, on db: any Database
    ) async throws -> [String] {
        try await APICompositeReference.query(on: db).filter(\.$assignmentID == assignmentID).delete()
        let held = [SubmissionStatus.assigned, .running].map(\.rawValue)
        let earlier = try await APISubmission.query(on: db)
            .filter(\.$testSetupID == testSetupID)
            .filter(\.$kind == APISubmission.Kind.compositeReference)
            .filter(\.$status !~ held)
            .all()
        guard !earlier.isEmpty else { return [] }
        try await APISubmission.query(on: db).filter(\.$id ~~ earlier.compactMap(\.id)).delete()
        return earlier.flatMap { [$0.zipPath, $0.zipPath + ".grading"] }
    }

    /// The slot inputs of a reference job: the slot its row names.
    static func gradingInputs(
        manifest: TestProperties, submissionID: String?, on db: any Database
    ) async
        -> [String: String]?
    {
        guard let submissionID, let activity = manifest.activity, let spec = activity.composite,
            let language = AssignmentLanguage.resolve(manifest: manifest)
        else { return nil }
        let row: APICompositeReference?
        do {
            row = try await APICompositeReference.query(on: db).filter(\.$submissionID == submissionID).first()
        } catch {
            db.logger.warning("composite: reference row lookup for \(submissionID) failed: \(error)")
            return nil
        }
        guard let row else {
            // A render replaced while this job waited: the job has no slot.
            db.logger.warning("composite: reference job \(submissionID) has no reference row")
            return nil
        }
        return spec.inputs(forSlot: row.slot).mapValues(language.literal)
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
        return (rows.count(where: { $0.passed && $0.data != nil }), rows.count)
    }
}
