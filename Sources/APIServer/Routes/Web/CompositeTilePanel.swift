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
    /// "Your tile: column 3, row 5", or "Slot 12 of 48" for a sequence.
    let slotText: String
    /// "Passed" or "Did not pass".
    let stateText: String
    let passed: Bool
    let stage: CompositeStagePresentation

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
            let slot = try await APICompositeSlot.query(on: db)
                .filter(\.$assignmentID == assignmentID)
                .filter(\.$userID == userID)
                .first()?.slot
        else { return nil }

        let place: String
        if let position = spec.gridPosition(ofSlot: slot) {
            place = "column \(position.column + 1), row \(position.row + 1)"
        } else {
            place = "slot \(slot + 1) of \(spec.layout.slotCount)"
        }
        let passed = outcome.status == .pass
        return CompositeTilePanel(
            slotText: (viewerIsOwner ? "Your tile: " : "Tile: ") + place,
            stateText: passed ? "Passed" : "Did not pass",
            passed: passed,
            stage: .ownTile(spec: spec, pixels: contribution.data, passed: passed))
    }
}
