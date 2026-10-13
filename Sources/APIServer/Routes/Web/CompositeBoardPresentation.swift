// APIServer/Routes/Web/CompositeBoardPresentation.swift
//
// The part of a class composite's leaderboard that the region poll refreshes
// (docs/class-composite.md, slice 5): the progress line and, for staff, who
// holds each slot and how it stands. The canvas is outside the region and
// polls its own JSON, so a swap here never replaces it.

import Core
import Fluent
import Foundation

struct CompositeBoardPresentation {

    /// One dealt slot and its holder, for the staff list.
    struct Holder {
        /// "Column 3, row 5", or "Slot 12".
        let place: String
        /// The class handle, with the name for staff.
        let who: String
        /// "Passed", "Did not pass" or "No contribution", with "grading" when
        /// a submission is in flight.
        let stateText: String
        /// `tier-open`, `tier-danger` or empty: the state's chip.
        let tierClass: String
    }

    /// The canvas, drawn outside the polled region.
    let stage: CompositeStagePresentation
    /// "31 of 48 tiles complete".
    let progressText: String
    /// Every dealt slot, in slot order, then round.
    let holders: [Holder]

    /// The staff board of a class composite, or nil for any other kind.
    static func build(
        setup: APITestSetup, activity: ClassActivity, assignment: APIAssignment?, on db: any Database
    ) async throws -> CompositeBoardPresentation? {
        guard activity.kind == .classComposite, let spec = activity.composite, let assignmentID = assignment?.id,
            let testSetupID = setup.id
        else { return nil }
        let courseID = setup.courseID
        // `since: .max` asks for the states only, with no pixels.
        let snapshot = try await CompositeSnapshot.build(
            .init(assignmentID: assignmentID, testSetupID: testSetupID, courseID: courseID, spec: spec),
            since: .max, onlyUserID: nil, includeOwners: false, on: db)
        let stateBySlot = Dictionary(snapshot.slots.map { ($0.slot, $0) }) { first, _ in first }

        let dealt = try await APICompositeSlot.query(on: db)
            .filter(\.$assignmentID == assignmentID)
            .sort(\.$slot).sort(\.$round)
            .all()
        let userIDs = dealt.map(\.userID)
        let users = Dictionary(
            try await APIUser.query(on: db).filter(\.$id ~~ userIDs).all().compactMap { user in
                user.id.map { ($0, user) }
            }
        ) { first, _ in first }
        let handles = Dictionary(
            try await APICourseEnrollment.query(on: db)
                .filter(\.$course.$id == courseID)
                .filter(\.$userID ~~ userIDs)
                .all()
                .compactMap { enrollment in enrollment.avatarHandle.map { (enrollment.userID, $0) } }
        ) { first, _ in first }

        let holders = dealt.map { row -> Holder in
            let name = users[row.userID].map { $0.displayName ?? $0.username } ?? "Unknown"
            let who = handles[row.userID].map { "\($0) · \(name)" } ?? name
            let state = stateBySlot[row.slot]
            var stateText: String
            let tierClass: String
            switch state?.state {
            case "passed":
                stateText = "Passed"
                tierClass = "tier-open"
            case "failed":
                stateText = "Did not pass"
                tierClass = "tier-danger"
            default:
                stateText = "No contribution"
                tierClass = ""
            }
            if state?.rendering == true { stateText += ", grading" }
            return Holder(place: place(of: row.slot, in: spec), who: who, stateText: stateText, tierClass: tierClass)
        }
        return CompositeBoardPresentation(
            stage: .board(
                spec: spec, testSetupID: testSetupID, present: false, pollUntilISO: activity.window?.closesAtISO),
            progressText: "\(snapshot.complete) of \(snapshot.total) \(spec.compositor.slotNoun) complete",
            holders: holders)
    }

    /// "Column 3, row 5" for a grid, "Slot 12" otherwise: one-based, as people
    /// count.
    static func place(of slot: Int, in spec: CompositeSpec) -> String {
        if let position = spec.gridPosition(ofSlot: slot) {
            return "Column \(position.column + 1), row \(position.row + 1)"
        }
        return "Slot \(slot + 1)"
    }
}

extension CompositeCompositor {
    /// What one slot is, in the progress line: "31 of 48 tiles complete".
    var slotNoun: String {
        switch self {
        case .tile: return "tiles"
        case .gallery: return "panels"
        case .sequence: return "frames"
        case .sum: return "angles"
        }
    }
}
