// APIServer/Services/CompositeSnapshot.swift
//
// What the composite view draws (docs/class-composite.md, slice 5): the state
// of every dealt slot, and the pixels of each slot that changed
// after the client's cursor. `GET /testsetups/:id/composite` returns it as
// JSON, so the polled HTML stays small and the canvas is never replaced.
//
// A slot shows its latest passing contribution. With no passing contribution
// it shows its latest failed one, unless `showFailed` is off. With two
// students on one slot (a second round), the latest passing one wins. A slot
// with no passing contribution shows a passing spare (slice 6b), and then,
// with `emptySlots: reference`, its reference render. A slot is "rendering"
// while a submission by its holder waits for a runner or is grading: the
// submission status the server already stores.

import Core
import Fluent
import Foundation
import Vapor

struct CompositeSnapshot: Content, Equatable {

    /// One slot that is dealt, rendering or showing a contribution.
    struct Slot: Content, Equatable {
        let slot: Int
        /// `passed`, `failed`, `reference` (the dimmed reference render) or
        /// `empty`.
        let state: String
        let rendering: Bool
        /// The holder's class handle. Staff only, and only on the staff page.
        let owner: String?
    }

    /// The pixels of one slot: standard padded base64, as the script
    /// reported them.
    struct Pixels: Content, Equatable {
        let slot: Int
        let data: String
    }

    /// Pass back as `since`: the pixels of a slot are sent again only when
    /// one of its contributions changed after it.
    let cursor: String
    /// Slots that show a passing contribution.
    let complete: Int
    let total: Int
    let slots: [Slot]
    let pixels: [Pixels]

    /// The assignment a snapshot is of.
    struct Scope {
        let assignmentID: UUID
        let testSetupID: String
        let courseID: UUID
        let spec: CompositeSpec
    }

    /// Builds the snapshot of one assignment's composite.
    ///
    /// `since: .max` returns the states with no pixels. `onlyUserID` limits
    /// it to one student's own slot: the student view. `includeOwners` adds
    /// each slot holder's handle, for the staff page.
    static func build(
        _ scope: Scope, since: Int64?, onlyUserID: UUID?, includeOwners: Bool, on db: any Database
    ) async throws -> CompositeSnapshot {
        let assignmentID = scope.assignmentID
        let testSetupID = scope.testSetupID
        let courseID = scope.courseID
        let spec = scope.spec
        var rowQuery = APICompositeContribution.query(on: db).filter(\.$assignmentID == assignmentID)
        var slotQuery = APICompositeSlot.query(on: db).filter(\.$assignmentID == assignmentID)
        if let onlyUserID {
            rowQuery = rowQuery.filter(\.$userID == onlyUserID)
            slotQuery = slotQuery.filter(\.$userID == onlyUserID)
        }
        let rows = try await rowQuery.all()
        let dealt = try await slotQuery.all()
        let slotByUser = Dictionary(dealt.map { ($0.userID, $0.slot) }) { first, _ in first }
        // The holder a slot names when it shows no contribution: the newest
        // round, then the lowest user ID, so every poll and every server
        // names the same student.
        let holderBySlot = Dictionary(
            dealt.sorted { ($0.round, $1.userID.uuidString) > ($1.round, $0.userID.uuidString) }
                .map { ($0.slot, $0.userID) }
        ) { first, _ in first }

        let inFlight = [SubmissionStatus.pending, .assigned, .running].map(\.rawValue)
        let renderingSlots: Set<Int> =
            slotByUser.isEmpty
            ? []
            : Set(
                try await APISubmission.query(on: db)
                    .filter(\.$testSetupID == testSetupID)
                    .filter(\.$kind == APISubmission.Kind.student)
                    .filter(\.$status ~~ inFlight)
                    .filter(\.$userID ~~ Array(slotByUser.keys))
                    .all()
                    .compactMap { $0.userID.flatMap { slotByUser[$0] } })

        let bySlot = Dictionary(grouping: rows, by: \.slot)
        var shown: [Int: APICompositeContribution] = [:]
        for (slot, slotRows) in bySlot {
            let newestFirst = slotRows.sorted { $0.submittedAt > $1.submittedAt }
            shown[slot] = newestFirst.first(where: \.passed) ?? (spec.showFailed ? newestFirst.first : nil)
        }

        let fills = onlyUserID == nil ? try await emptySlotFills(scope, shown: shown, on: db) : Fills()
        let spares = fills.spares
        let references = fills.references
        // A passing spare replaces a failed contribution on show.
        shown = shown.filter { spares[$0.key] == nil }

        let ownerIDs = Array(slotByUser.keys) + spares.values.map(\.userID)
        let owners = includeOwners ? try await handles(of: ownerIDs, inCourse: courseID, on: db) : [:]
        let listed = Set(shown.keys).union(renderingSlots).union(holderBySlot.keys).union(references.keys)
            .union(spares.keys)
        let slots = listed.sorted().map { slot in
            let row = shown[slot]
            let state =
                spares[slot] != nil
                ? "passed"
                : row.map { $0.passed ? "passed" : "failed" } ?? (references[slot] == nil ? "empty" : "reference")
            let ownerID = spares[slot]?.userID ?? row?.userID ?? holderBySlot[slot]
            return Slot(
                slot: slot, state: state, rendering: renderingSlots.contains(slot),
                owner: ownerID.flatMap { owners[$0] })
        }

        func millis(_ date: Date?) -> Int64 { Int64(((date ?? .distantPast).timeIntervalSince1970 * 1000).rounded()) }
        var pixels = shown.keys.sorted().compactMap { slot -> Pixels? in
            guard let row = shown[slot] else { return nil }
            let changed = bySlot[slot, default: []].map { millis($0.updatedAt) }.max() ?? 0
            guard since.map({ changed >= $0 }) ?? true else { return nil }
            return Pixels(slot: slot, data: row.data)
        }
        // A spare or a reference pixel is sent on every poll that asks for
        // pixels. A slot can fall back to one when a row is deleted, and a
        // deleted row moves no cursor, so `since` cannot see it.
        if since != .max {
            pixels += spares.compactMap { slot, spare in spare.data.map { Pixels(slot: slot, data: $0) } }
            pixels += references.compactMap { slot, reference in reference.data.map { Pixels(slot: slot, data: $0) } }
        }
        pixels.sort { $0.slot < $1.slot }
        let changes = rows.map(\.updatedAt) + spares.values.map(\.updatedAt) + references.values.map(\.updatedAt)
        let cursor = changes.map(millis).max() ?? 0

        return CompositeSnapshot(
            cursor: String(cursor),
            complete: shown.values.filter(\.passed).count + spares.count,
            total: spec.layout.slotCount,
            slots: slots,
            pixels: pixels)
    }

    /// What fills the slots that show no passing contribution. Never in the
    /// student view: a student sees only their own slot.
    struct Fills {
        var spares: [Int: APICompositeSpare] = [:]
        var references: [Int: APICompositeReference] = [:]
    }

    /// A passing spare fills a slot first (docs/class-composite.md,
    /// slice 6b). With `emptySlots: reference`, a slot that shows nothing
    /// else shows its reference render, dimmed. A row whose length is not the
    /// spec's (the spec changed after it was made) is left out.
    private static func emptySlotFills(
        _ scope: Scope, shown: [Int: APICompositeContribution], on db: any Database
    ) async throws -> Fills {
        let spec = scope.spec
        let count = spec.layout.slotCount
        let shape = spec.contribution
        let length = (shape.width * shape.height * shape.frames * shape.format.channels + 2) / 3 * 4
        func fits(_ slot: Int, _ data: String?) -> Bool { slot < count && data?.utf8.count == length }

        var fills = Fills()
        let filled = Set(shown.filter(\.value.passed).keys)
        for row in try await APICompositeSpare.query(on: db).filter(\.$assignmentID == scope.assignmentID).all()
        where row.passed && !filled.contains(row.slot) && fits(row.slot, row.data) {
            fills.spares[row.slot] = row
        }
        guard spec.emptySlots == .reference else { return fills }
        let covered = Set(shown.keys).union(fills.spares.keys)
        for row in try await APICompositeReference.query(on: db).filter(\.$assignmentID == scope.assignmentID).all()
        where row.passed && !covered.contains(row.slot) && fits(row.slot, row.data) {
            fills.references[row.slot] = row
        }
        return fills
    }

    /// The class handle of each student, by user ID. A student with no handle
    /// yet has no entry.
    private static func handles(
        of userIDs: [UUID], inCourse courseID: UUID, on db: any Database
    ) async throws
        -> [UUID: String]
    {
        guard !userIDs.isEmpty else { return [:] }
        let enrollments = try await APICourseEnrollment.query(on: db)
            .filter(\.$course.$id == courseID)
            .filter(\.$userID ~~ userIDs)
            .all()
        var handles: [UUID: String] = [:]
        for enrollment in enrollments {
            if let handle = enrollment.avatarHandle { handles[enrollment.userID] = handle }
        }
        return handles
    }
}
