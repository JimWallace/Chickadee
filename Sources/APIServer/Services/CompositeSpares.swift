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
//
// A composite that runs once per lab group fills each group's holes from
// that group's spares (docs/lab-groups.md, slice 4b): a student fills holes
// in the image their own tile is in, while their session is open.

import Core
import Fluent
import Foundation
import Vapor

enum CompositeSpares {

    enum RequestError: Error, Equatable {
        /// The assignment is not a class composite.
        case notComposite
        /// The composite runs once per lab group, and the student does not
        /// play in an open session of their tile's group.
        case sessionClosed
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
        // The spare fills the image the student's own tile is in.
        let pool: CompositePool =
            own.groupID.map { .group(assignmentID: assignmentID, groupID: $0) } ?? .course(assignmentID: assignmentID)
        guard try await playsInSession(of: pool, userID: userID, on: db) else { throw RequestError.sessionClosed }
        guard try await !status(in: pool, userID: userID, on: db).contains(where: \.grading)
        else { throw RequestError.inFlight }

        let seed = try await AssignmentSeedStore.ensureSeed(userID: userID, assignmentID: assignmentID, on: db)
        // The student's course cohort seed, pinned beside the assignment seed
        // so a course-scoped dataset gives the spare the student's own rows.
        var courseSeed: String?
        // On a composite the deal number of a partition dataset is the slot
        // rendered, so a spare for a hole reads the hole's part
        // (docs/datasets-course-library.md §4.11).
        var hasPartitions = false
        if let manifest = setup.decodedManifest() {
            courseSeed = try await CourseSeedStore.seedIfNeeded(
                manifest: manifest, userID: userID, courseID: setup.courseID, on: db)
            hasPartitions = manifest.hasPartitionedDatasets
        }
        // Two students can choose one hole at the same moment. The loser
        // takes the next hole.
        for _ in 0..<4 {
            guard
                let slot = try await holes(in: pool, spec: spec, skippingFailuresOf: userID, on: db).first
            else { throw RequestError.noHole }
            let job = Job(
                pool: pool, setupID: setupID, userID: userID, slot: slot, source: source, seed: seed,
                courseSeed: courseSeed, dealNumber: hasPartitions ? slot : nil)
            if try await queue(job, app: app, on: db) { return slot }
        }
        throw RequestError.noHole
    }

    /// True for the whole class's image, and for a lab group's while the
    /// student plays in that group's open session: a lab fills its holes
    /// during the lab.
    static func playsInSession(of pool: CompositePool, userID: UUID, on db: any Database) async throws -> Bool {
        guard let groupID = pool.groupID else { return true }
        let session = try await ActivitySessionStore.currentSession(
            assignmentID: pool.assignmentID, userID: userID, on: db)
        return session?.groupID == groupID
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
        try await holes(in: .course(assignmentID: assignmentID), spec: spec, skippingFailuresOf: userID, on: db)
    }

    // The `assignmentID` forms above and below name the whole class's pool,
    // and the slice 6b tests call them.

    /// The holes of one pool's image, in the order `holes(assignmentID:)`
    /// gives.
    static func holes(
        in pool: CompositePool, spec: CompositeSpec, skippingFailuresOf userID: UUID? = nil, on db: any Database
    ) async throws -> [Int] {
        let filled = Set(
            try await APICompositeContribution.query(on: db)
                .filter(\.$assignmentID == pool.assignmentID).filter(\.$groupID == pool.groupID)
                .filter(\.$passed == true).all().map(\.slot))
        let taken = Set(
            try await pool.spares(on: db)
                .filter { $0.passed || !$0.finished || ($0.userID == userID && $0.finished) }.map(\.slot))
        let dealt = Set(try await pool.dealt(on: db).map(\.slot))
        let open = spec.dealSequence(shuffleSeed: CompositeSlots.shuffleSeed(for: pool.assignmentID))
            .filter { !filled.contains($0) && !taken.contains($0) }
        return open.filter { !dealt.contains($0) } + open.filter { dealt.contains($0) }
    }

    /// The student's spares in the whole class's image, lowest slot first.
    static func status(assignmentID: UUID, userID: UUID, on db: any Database) async throws -> [Status] {
        try await status(in: .course(assignmentID: assignmentID), userID: userID, on: db)
    }

    /// The student's spares in one pool's image, lowest slot first.
    static func status(in pool: CompositePool, userID: UUID, on db: any Database) async throws -> [Status] {
        try await pool.spares(onlyUserID: userID, on: db)
            .map { Status(slot: $0.slot, grading: !$0.finished, passed: $0.passed && $0.data != nil) }
    }

    /// One spare to queue.
    private struct Job {
        let pool: CompositePool
        let setupID: String
        let userID: UUID
        let slot: Int
        let source: APISubmission
        let seed: String
        let courseSeed: String?
        let dealNumber: Int?
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
            testSetupsDirectory: app.testSetupsDirectory, app: app, on: db, variantSeedHex: job.seed,
            variantCourseSeedHex: job.courseSeed, variantDealNumber: job.dealNumber)
        do {
            // With no materialization the job would grade with no seed.
            guard submission.materializationJSON != nil else { throw RequestError.unavailable }
            let removed = try await db.transaction { tx in
                // One spare at a time, checked again where a double press meets.
                let spares = try await job.pool.spares(onlyUserID: job.userID, on: tx)
                guard spares.allSatisfy(\.finished) else { throw RequestError.inFlight }
                let removed = try await removeFailed(in: job.pool, slot: job.slot, on: tx)
                try await materialized.saveClaimable(on: tx)
                try await job.pool.newSpare(userID: job.userID, slot: job.slot, submissionID: copied.id)
                    .create(on: tx)
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
            guard let row = try await CompositePool.spare(submissionID: submissionID, on: db)?.row else {
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
    /// the student, in the class's coverage or in its lab's
    /// (docs/lab-groups.md, slice 5b); the first to cover a slot keeps it, as
    /// for every item.
    static func record(
        submission: APISubmission, collection: TestOutcomeCollection, on db: any Database
    )
        async throws
    {
        guard submission.kind == APISubmission.Kind.compositeSpare, let submissionID = submission.id,
            let spare = try await CompositePool.spare(submissionID: submissionID, on: db),
            let spec = try await APITestSetup.find(submission.testSetupID, on: db)?
                .decodedManifest()?.activity?.composite
        else { return }
        let row = spare.row
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
        guard row.passed else { return }
        let item = CompositeSpec.coverageItem(forSlot: row.slot)
        if let groupID = spare.pool.groupID {
            try await recordLabItemCoverage(
                testSetupID: submission.testSetupID, groupID: groupID, items: [item], userID: row.userID,
                submissionID: submissionID, on: db)
        } else {
            try await APIClassItemCoverage(
                testSetupID: submission.testSetupID, item: item, userID: row.userID, submissionID: submissionID
            ).createIgnoringConflict(on: db)
        }
    }

    /// Removes a failed spare from `slot`, so a new one can take the slot.
    /// Returns the files of its job, to delete after the commit. A spare that
    /// passed or is grading stays: another request queued it after the holes
    /// were read, and the insert that follows then fails on the slot.
    private static func removeFailed(in pool: CompositePool, slot: Int, on db: any Database) async throws -> [String] {
        guard
            let failed = try await pool.spares(on: db).first(where: { $0.slot == slot }),
            failed.finished, !failed.passed,
            let job = try await APISubmission.find(failed.submissionID, on: db)
        else { return [] }
        try await failed.delete(on: db)
        try await job.delete(on: db)
        return [job.zipPath, job.zipPath + ".grading"]
    }
}
