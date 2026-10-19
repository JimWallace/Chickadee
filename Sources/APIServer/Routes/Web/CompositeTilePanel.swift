// APIServer/Routes/Web/CompositeTilePanel.swift
//
// The result page's view of one submission's contribution to a class
// composite (docs/class-composite.md, slice 5). The full composite is for the
// projector; a student sees only what they added to it, drawn at a larger
// scale, with its slot and whether it passed.

import Core
import Fluent
import Foundation

struct CompositeTilePanel: Encodable {
    /// One spare tile: "Spare tile: column 4, row 2" and its state badge.
    struct Spare: Encodable {
        let slotText: String
        /// "Passed", "Did not pass" or "Grading".
        let stateText: String
        /// The `.tier` class: open for passed, danger for failed, bare while
        /// grading.
        let tierClass: String
    }

    /// "Your tile: column 3, row 5", or "Slot 12 of 48" for a sequence.
    let slotText: String
    /// "Passed" or "Did not pass".
    let stateText: String
    let passed: Bool
    let stage: CompositeStagePresentation
    /// The owner's spare tiles (slice 6b), each shown like the own tile.
    var spares: [Spare] = []
    /// The "Fill a hole" form's action, when the owner may ask for a spare
    /// now: their tile passed, none of their spares is grading, the session
    /// is open, and a hole is left.
    var spareAction: String?

    /// The panel for `submission`, or nil when the assignment is not a class
    /// composite, the submission reported no valid contribution, or its
    /// owner holds no slot.
    static func make(
        for submission: APISubmission, _ collection: TestOutcomeCollection?, _ props: TestProperties?,
        _ assignment: APIAssignment?, viewer: APIUser, on db: any Database
    ) async throws -> CompositeTilePanel? {
        let viewerIsOwner = submission.userID == viewer.id
        guard let activity = props?.activity, activity.kind == .classComposite, let spec = activity.composite,
            let outcome = collection?.outcomes.first(where: { $0.composite != nil }),
            let contribution = outcome.composite,
            CompositeContributions.isValid(contribution, for: spec.contribution),
            let assignmentID = assignment?.id, let userID = submission.userID,
            let slot = try await CompositePool.dealtSlot(assignmentID: assignmentID, userID: userID, on: db)?.slot
        else { return nil }

        let passed = outcome.status == .pass
        var panel = CompositeTilePanel(
            slotText: (viewerIsOwner ? "Your tile: " : "Tile: ") + place(of: slot, in: spec),
            stateText: passed ? "Passed" : "Did not pass",
            passed: passed,
            stage: .ownTile(spec: spec, pixels: contribution.data, passed: passed))
        guard viewerIsOwner, let assignment else { return panel }
        let setupID = assignment.testSetupID

        let spares = try await CompositeSpares.status(assignmentID: assignmentID, userID: userID, on: db)
        panel.spares = spares.map { spare in
            let (text, tier) =
                spare.grading
                ? ("Grading", "tier")
                : spare.passed ? ("Passed", "tier tier-open") : ("Did not pass", "tier tier-danger")
            return Spare(slotText: "Spare tile: " + place(of: spare.slot, in: spec), stateText: text, tierClass: tier)
        }
        let ownPassed =
            try await APICompositeContribution.query(on: db)
            .filter(\.$assignmentID == assignmentID).filter(\.$userID == userID).first()?.passed ?? false
        // A lab's composite has no spares yet (docs/lab-groups.md, slice 4b).
        if ownPassed, !activity.isPerGroup, assignment.isOpen, activity.acceptsSubmissions(at: Date()),
            !spares.contains(where: \.grading),
            try await !CompositeSpares.holes(assignmentID: assignmentID, spec: spec, on: db).isEmpty
        {
            panel.spareAction = "/testsetups/\(setupID)/composite/spare"
        }
        return panel
    }

    /// "column 3, row 5" in a grid, or "slot 12 of 48".
    static func place(of slot: Int, in spec: CompositeSpec) -> String {
        if let position = spec.gridPosition(ofSlot: slot) {
            return "column \(position.column + 1), row \(position.row + 1)"
        }
        return "slot \(slot + 1) of \(spec.layout.slotCount)"
    }
}
