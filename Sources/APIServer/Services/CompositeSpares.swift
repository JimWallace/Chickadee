// APIServer/Services/CompositeSpares.swift
//
// The spare slots of a class composite (docs/class-composite.md, slice 6b).
// A student whose own tile passed can press "Fill a hole" on the result page.
// The server grades that passing submission again with the inputs of a slot
// that nothing fills, and a passing result fills the slot and covers it for
// the student.
//
// Each spare is one `compositeSpare` submission, owned by no student, so no
// listing, grade or attempt count sees it. Its row in `composite_spares` names
// the student it credits. The job is personalized with the student's own
// seed, so it runs with the values their own run had. The worker claims it
// behind every student job.

import Core
import Fluent
import Foundation
import Vapor

enum CompositeSpares {

    enum RequestError: Error, Equatable {
        /// The assignment is not a class composite.
        case notComposite
        /// The student's own tile has not passed.
        case noPassingTile
        /// A spare of the student's is still grading.
        case inFlight
        /// Every slot shows a passing tile or is being filled.
        case noHole
        /// The server could not pin the student's seed to the job.
        case unavailable
    }

    /// The student's spares, by slot.
    struct Status: Equatable {
        let slot: Int
        let grading: Bool
        let passed: Bool
    }

    /// Queues a spare for the student in the first hole, and returns its slot.
    static func request(
        assignment: APIAssignment, setup: APITestSetup, userID: UUID, app: Application, on db: any Database
    ) async throws -> Int {
        guard let assignmentID = assignment.id, let setupID = setup.id,
            let activity = setup.decodedManifest()?.activity, activity.kind == .classComposite,
            let spec = activity.composite
        else { throw RequestError.notComposite }
        guard
            let own = try await APICompositeContribution.query(on: db)
                .filter(\.$assignmentID == assignmentID).filter(\.$userID == userID).first(),
            own.passed,
            let source = try await APISubmission.find(own.submissionID, on: db),
            FileManager.default.fileExists(atPath: source.zipPath)
        else { throw RequestError.noPassingTile }
        guard try await !status(assignmentID: assignmentID, userID: userID, on: db).contains(where: \.grading)
        else { throw RequestError.inFlight }

        let seed = try await AssignmentSeedStore.ensureSeed(userID: userID, assignmentID: assignmentID, on: db)
        // Two students can choose one hole at the same moment. The loser
        // takes the next hole.
        for _ in 0..<4 {
            guard
                let slot = try await holes(assignmentID: assignmentID, spec: spec, skippingFailuresOf: userID, on: db)
                    .first
            else { throw RequestError.noHole }
            let job = Job(
                assignmentID: assignmentID, setupID: setupID, userID: userID, slot: slot, source: source, seed: seed)
            if try await queue(job, app: app, on: db) { return slot }
        }
        throw RequestError.noHole
    }

    /// The slots a spare may fill, in the order to fill them: no passing
    /// contribution, and no spare that passed or is grading. A slot that no
    /// student holds comes first, so a spare does not race a student who may
    /// still submit. Within each group, the deal order. A slot where the
    /// student's own spare failed is left out for them: the same code fails
    /// there again.
    static func holes(
        assignmentID: UUID, spec: CompositeSpec, skippingFailuresOf userID: UUID? = nil, on db: any Database
    ) async throws -> [Int] {
        let filled = Set(
            try await APICompositeContribution.query(on: db)
                .filter(\.$assignmentID == assignmentID).filter(\.$passed == true).all().map(\.slot))
        let spares = try await APICompositeSpare.query(on: db).filter(\.$assignmentID == assignmentID).all()
        let taken = Set(
            spares.filter { $0.passed || !$0.finished || ($0.userID == userID && $0.finished) }.map(\.slot))
        let dealt = Set(
            try await APICompositeSlot.query(on: db).filter(\.$assignmentID == assignmentID).all().map(\.slot))
        let open = spec.dealSequence(shuffleSeed: CompositeSlots.shuffleSeed(for: assignmentID))
            .filter { !filled.contains($0) && !taken.contains($0) }
        return open.filter { !dealt.contains($0) } + open.filter { dealt.contains($0) }
    }

    /// The student's spares, lowest slot first.
    static func status(assignmentID: UUID, userID: UUID, on db: any Database) async throws -> [Status] {
        try await APICompositeSpare.query(on: db)
            .filter(\.$assignmentID == assignmentID).filter(\.$userID == userID).sort(\.$slot).all()
            .map { Status(slot: $0.slot, grading: !$0.finished, passed: $0.passed && $0.data != nil) }
    }

    /// One spare to queue.
    private struct Job {
        let assignmentID: UUID
        let setupID: String
        let userID: UUID
        let slot: Int
        let source: APISubmission
        let seed: String
    }

    /// Queues one spare job for `job.slot`. False when another request took
    /// the slot first.
    private static func queue(_ job: Job, app: Application, on db: any Database) async throws -> Bool {
        let copied = try copySubmissionFile(from: job.source.zipPath, into: app.submissionsDirectory)
        let written = [copied.path, copied.path + ".grading"]
        let submission = APISubmission(
            id: copied.id, testSetupID: job.setupID, zipPath: copied.path, attemptNumber: 1,
            filename: job.source.filename, userID: nil, kind: APISubmission.Kind.compositeSpare)
        // The student's file is graded as they submitted it: there is no
        // template to substitute, only the seed and the inputs to pin.
        let materialized = await materializeValidationGrading(
            submission: submission, setupID: job.setupID, templateNotebookData: Data(),
            testSetupsDirectory: app.testSetupsDirectory, app: app, on: db, variantSeedHex: job.seed)
        do {
            // With no materialization the job would grade with no seed.
            guard submission.materializationJSON != nil else { throw RequestError.unavailable }
            let removed = try await db.transaction { tx in
                // One spare at a time, checked again where a double press meets.
                let grading = try await APICompositeSpare.query(on: tx)
                    .filter(\.$assignmentID == job.assignmentID).filter(\.$userID == job.userID)
                    .filter(\.$finished == false).count()
                guard grading == 0 else { throw RequestError.inFlight }
                let removed = try await removeFailed(assignmentID: job.assignmentID, slot: job.slot, on: tx)
                try await materialized.saveClaimable(on: tx)
                try await APICompositeSpare(
                    assignmentID: job.assignmentID, userID: job.userID, slot: job.slot, submissionID: copied.id
                ).create(on: tx)
                return removed
            }
            for path in removed { try? FileManager.default.removeItem(atPath: path) }
            return true
        } catch {
            for path in written { try? FileManager.default.removeItem(atPath: path) }
            if isInsertConflict(error) { return false }
            throw error
        }
    }

    /// The slot inputs of a spare job: the slot its row names.
    static func gradingInputs(
        manifest: TestProperties, submissionID: String?, on db: any Database
    ) async
        -> [String: String]?
    {
        guard let submissionID, let spec = manifest.activity?.composite,
            let language = AssignmentLanguage.resolve(manifest: manifest)
        else { return nil }
        do {
            guard
                let row = try await APICompositeSpare.query(on: db)
                    .filter(\.$submissionID == submissionID).first()
            else {
                db.logger.warning("composite: spare job \(submissionID) has no spare row")
                return nil
            }
            return spec.inputs(forSlot: row.slot).mapValues(language.literal)
        } catch {
            db.logger.warning("composite: spare row lookup for \(submissionID) failed: \(error)")
            return nil
        }
    }

    /// Stores what a spare job reported. A passing spare covers its slot for
    /// the student; the first to cover a slot keeps it, as for every item.
    static func record(
        submission: APISubmission, collection: TestOutcomeCollection, on db: any Database
    )
        async throws
    {
        guard submission.kind == APISubmission.Kind.compositeSpare, let submissionID = submission.id,
            let row = try await APICompositeSpare.query(on: db)
                .filter(\.$submissionID == submissionID).first(),
            let spec = try await APITestSetup.find(submission.testSetupID, on: db)?
                .decodedManifest()?.activity?.composite
        else { return }
        guard let outcome = collection.outcomes.first(where: { $0.composite != nil }),
            let contribution = outcome.composite,
            CompositeContributions.isValid(contribution, for: spec.contribution)
        else {
            db.logger.warning("composite: spare job \(submissionID) reported no valid render")
            row.data = nil
            row.passed = false
            row.finished = true
            try await row.save(on: db)
            return
        }
        row.data = contribution.data
        row.passed = outcome.status == .pass
        row.finished = true
        try await row.save(on: db)
        if row.passed {
            try await APIClassItemCoverage(
                testSetupID: submission.testSetupID, item: CompositeSpec.coverageItem(forSlot: row.slot),
                userID: row.userID, submissionID: submissionID
            ).createIgnoringConflict(on: db)
        }
    }

    /// Removes a failed spare from `slot`, so a new one can take the slot.
    /// Returns the files of its job, to delete after the commit. A spare that
    /// passed or is grading stays: another request queued it after the holes
    /// were read, and the insert that follows then fails on the slot.
    private static func removeFailed(assignmentID: UUID, slot: Int, on db: any Database) async throws -> [String] {
        guard
            let failed = try await APICompositeSpare.query(on: db)
                .filter(\.$assignmentID == assignmentID).filter(\.$slot == slot).first(),
            failed.finished, !failed.passed,
            let job = try await APISubmission.find(failed.submissionID, on: db)
        else { return [] }
        try await failed.delete(on: db)
        try await job.delete(on: db)
        return [job.zipPath, job.zipPath + ".grading"]
    }
}
