// APIServer/Views/CompositeTileSection.swift
//
// The result page's class-composite section (docs/class-composite.md,
// slice 5): the student's own contribution, its place in the shared image,
// and whether it passed. The full composite is for the projector.

import Elementary

struct CompositeTileSection: HTML {
    let tile: CompositeTilePanel

    var body: some HTML {
        section(.class("class-goals-block"), .ariaLabel("Class composite")) {
            h2(.class("class-goals-heading")) { "Class composite" }
            p(.class("section-note")) {
                "\(tile.slotText) · "
                span(.class(tile.passed ? "tier tier-open" : "tier tier-closed")) { tile.stateText }
            }
            div(.class("composite-tile")) {
                CompositeStage(stage: tile.stage)
            }
        }
    }
}
