// APIServer/Services/CompositeSlots.swift
//
// Deals the slots of a class composite and turns a dealt slot into the
// per-student inputs a test script reads (docs/class-composite.md, slice 3).
//
// A slot is dealt the first time a student opens the assignment while its
// session window is open, or, as a backstop, when their first submission is
// graded. It does not change after that. The dealer takes the first free
// (round, slot) pair in `CompositeSpec.dealSequence` order, so a slot freed by
// a deleted student is dealt again, and a second round starts only when every
// slot of the first is taken.
//
// Dealing writes on a page load, so it is safe under a race: the unique keys
// on `composite_slots` refuse a second row for a student and a second student
// for a (round, slot). A loser re-reads its own row, or tries the next free
// pair. No insert runs inside a transaction: on Postgres a failed insert
// aborts the transaction, and the re-read would then throw.

import Core
import Fluent
import Foundation
import Vapor

enum CompositeSlots {

    /// The student's slot, dealing one if they have none.
    static func slot(
        assignmentID: UUID, userID: UUID, spec: CompositeSpec, on db: any Database
    ) async throws -> Int {
        if let existing = try await dealtSlot(assignmentID: assignmentID, userID: userID, on: db) {
            return existing
        }
        let sequence = spec.dealSequence(shuffleSeed: shuffleSeed(for: assignmentID))
        var attempt = 0
        while true {
            let taken = try await APICompositeSlot.query(on: db)
                .filter(\.$assignmentID == assignmentID)
                .all()
                .map { DealtPosition(round: $0.round, slot: $0.slot) }
            let next = firstFree(in: sequence, taken: Set(taken))
            let row = APICompositeSlot(
                assignmentID: assignmentID, userID: userID, slot: next.slot, round: next.round)
            do {
                try await row.create(on: db)
                return row.slot
            } catch let error where isInsertConflict(error) && attempt < 8 {
                attempt += 1
                // A concurrent request may have dealt this student first.
                if let existing = try await dealtSlot(assignmentID: assignmentID, userID: userID, on: db) {
                    return existing
                }
            }
        }
    }

    /// Deals a slot when a student opens a class-composite assignment inside
    /// its session window. Never fails the page: a dealing error is logged,
    /// and the grading backstop deals the slot later.
    static func dealOnOpen(
        setup: APITestSetup, assignment: APIAssignment, userID: UUID, now: Date = Date(),
        on db: any Database
    ) async {
        guard let assignmentID = assignment.id,
            let activity = setup.decodedManifest()?.activity,
            activity.kind == .classComposite, let spec = activity.composite,
            activity.acceptsSubmissions(at: now)
        else { return }
        do {
            _ = try await slot(assignmentID: assignmentID, userID: userID, spec: spec, on: db)
        } catch {
            db.logger.error("composite: dealing a slot on open failed: \(error)")
        }
    }

    /// True once any slot of the assignment has been dealt. With a student
    /// submission, this locks the composite's structure.
    static func hasDealtSlots(assignmentID: UUID, on db: any Database) async throws -> Bool {
        try await APICompositeSlot.query(on: db).filter(\.$assignmentID == assignmentID).count() > 0
    }

    /// The composite inputs for one grading run, rendered in the manifest's
    /// declared language, or nil when the assignment is not a class
    /// composite or has no language.
    ///
    /// A validation run (`usesReferenceSlot`) and any run by course staff or
    /// an admin get slot 0 and deal nothing: a dealt slot is a student's, and
    /// a staff member's submission is stored as a student one. A student's
    /// run gets their dealt slot, dealing one if needed. This is the backstop
    /// deal, so it ignores the session window: a first submission after the
    /// window (under an extension, say) is still dealt a slot.
    ///
    /// Never fails grading: an error is logged, and the run grades without
    /// the inputs (the test script then fails closed on its own).
    static func gradingInputs(
        manifest: TestProperties, courseID: UUID, assignmentID: UUID?, userID: UUID?,
        usesReferenceSlot: Bool, on db: any Database
    ) async -> [String: String]? {
        guard let activity = manifest.activity, activity.kind == .classComposite,
            let spec = activity.composite, let language = AssignmentLanguage.resolve(manifest: manifest)
        else { return nil }
        let slot: Int
        do {
            if usesReferenceSlot {
                slot = 0
            } else {
                guard let assignmentID, let userID else { return nil }
                if let user = try await APIUser.find(userID, on: db),
                    try await isCourseStaff(user, inCourse: courseID, db: db)
                {
                    slot = 0
                } else {
                    slot = try await Self.slot(assignmentID: assignmentID, userID: userID, spec: spec, on: db)
                }
            }
        } catch {
            db.logger.error("composite: resolving a slot for grading failed: \(error)")
            return nil
        }
        return spec.inputs(forSlot: slot).mapValues(language.literal)
    }

    /// The composite inputs of one grading job, by its kind: slot 0 for a
    /// validation run, the row's slot for a reference or a spare job, and the
    /// student's dealt slot otherwise.
    static func jobInputs(
        manifest: TestProperties, courseID: UUID, assignmentID: UUID?, submission: APISubmission,
        on db: any Database
    ) async -> [String: String]? {
        if submission.kind == APISubmission.Kind.compositeReference {
            return await CompositeReferences.gradingInputs(manifest: manifest, submissionID: submission.id, on: db)
        }
        if submission.kind == APISubmission.Kind.compositeSpare {
            return await CompositeSpares.gradingInputs(manifest: manifest, submissionID: submission.id, on: db)
        }
        return await gradingInputs(
            manifest: manifest, courseID: courseID, assignmentID: assignmentID,
            // Only a student's own submission is dealt a slot.
            userID: submission.kind == APISubmission.Kind.student ? submission.userID : nil,
            usesReferenceSlot: submission.kind == APISubmission.Kind.validation, on: db)
    }

    /// Merges composite inputs over the personalization inputs. The composite
    /// names are reserved (`CompositeSpec.slotInputName` and its siblings),
    /// so the composite's value wins a clash.
    static func merged(_ inputs: [String: String]?, with composite: [String: String]?) -> [String: String]? {
        guard let composite else { return inputs }
        return (inputs ?? [:]).merging(composite) { _, new in new }
    }

    // MARK: - Private

    private struct DealtPosition: Hashable {
        let round: Int
        let slot: Int
    }

    private static func dealtSlot(assignmentID: UUID, userID: UUID, on db: any Database) async throws -> Int? {
        try await APICompositeSlot.query(on: db)
            .filter(\.$assignmentID == assignmentID)
            .filter(\.$userID == userID)
            .first()?
            .slot
    }

    /// The first (round, slot) in deal order that nobody holds.
    private static func firstFree(in sequence: [Int], taken: Set<DealtPosition>) -> DealtPosition {
        var round = 0
        while true {
            for slot in sequence where !taken.contains(DealtPosition(round: round, slot: slot)) {
                return DealtPosition(round: round, slot: slot)
            }
            round += 1
        }
    }

    /// The `random` order's seed: FNV-1a over the assignment's ID, so one
    /// assignment always deals in one order, on every server.
    static func shuffleSeed(for assignmentID: UUID) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in assignmentID.uuidString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }
}
