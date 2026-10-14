// APIServer/Views/CompositeTileSection.swift
//
// The result page's class-composite section (docs/class-composite.md,
// slice 5): the student's own contribution, its place in the shared image,
// and whether it passed. The full composite is for the projector. With a
// passing tile, "Fill a hole" asks for a spare (slice 6b).

import Elementary

struct CompositeTileSection: HTML {
    let tile: CompositeTilePanel
    let csrfToken: String
    /// Where the "Fill a hole" request returns.
    let submissionID: String

    var body: some HTML {
        section(.class("page-section"), .ariaLabel("Class composite")) {
            h2 { "Class composite" }
            p {
                "\(tile.slotText) "
                span(.class(tile.passed ? "tier tier-open" : "tier tier-danger")) { tile.stateText }
            }
            div(.class("composite-tile")) {
                CompositeStage(stage: tile.stage)
            }
            for spare in tile.spares {
                p {
                    "\(spare.slotText) "
                    span(.class(spare.tierClass)) { spare.stateText }
                }
            }
            if let action = tile.spareAction {
                form(.method(.post), .action(action), .class("inline-form form-flush")) {
                    CSRFField(token: csrfToken)
                    input(.type(.hidden), .name("submissionID"), .value(submissionID))
                    button(.class("btn btn-primary"), .type(.submit)) { "Fill a hole" }
                }
                p(.class("field-note field-note--muted")) {
                    "Grades your passing code again for an empty slot, and the tile counts for you."
                }
            }
        }
    }
}
