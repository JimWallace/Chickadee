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
// is "rendering" while a submission by its holder waits for a runner or is
// grading: the submission status the server already stores.

import Core
import Fluent
import Foundation
import Vapor

struct CompositeSnapshot: Content, Equatable {

    /// One slot that is dealt, rendering or showing a contribution.
    struct Slot: Content, Equatable {
        let slot: Int
        /// `passed`, `failed` or `empty`.
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
        let assignmentID = scope.assignmentID, testSetupID = scope.testSetupID
        let courseID = scope.courseID, spec = scope.spec
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

        let owners = includeOwners ? try await handles(of: Array(slotByUser.keys), inCourse: courseID, on: db) : [:]
        let slots = Set(shown.keys).union(renderingSlots).union(holderBySlot.keys).sorted().map { slot in
            let row = shown[slot]
            let state = row.map { $0.passed ? "passed" : "failed" } ?? "empty"
            let ownerID = row?.userID ?? holderBySlot[slot]
            return Slot(
                slot: slot, state: state, rendering: renderingSlots.contains(slot),
                owner: ownerID.flatMap { owners[$0] })
        }

        func millis(_ date: Date?) -> Int64 { Int64(((date ?? .distantPast).timeIntervalSince1970 * 1000).rounded()) }
        let pixels = shown.keys.sorted().compactMap { slot -> Pixels? in
            guard let row = shown[slot] else { return nil }
            let changed = bySlot[slot, default: []].map { millis($0.updatedAt) }.max() ?? 0
            guard since.map({ changed >= $0 }) ?? true else { return nil }
            return Pixels(slot: slot, data: row.data)
        }
        let cursor = rows.map { millis($0.updatedAt) }.max() ?? 0

        return CompositeSnapshot(
            cursor: String(cursor),
            complete: shown.values.filter(\.passed).count,
            total: spec.layout.slotCount,
            slots: slots,
            pixels: pixels)
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
