// APIServer/Views/CompositeStage.swift
//
// One class-composite stage (docs/class-composite.md, slice 5): the canvas,
// one cell for each slot that `class-composite.js` creates and classes, the
// playback controls when the view moves, and the progress line. The
// leaderboard page, present mode and the result page render this one struct.

import Core
import Elementary

struct CompositeStage: HTML {
    let stage: CompositeStagePresentation

    var body: some HTML {
        div(
            .class("composite-stage js-class-composite"),
            .data("composite-compositor", value: stage.spec.compositor.rawValue),
            .data("composite-cols", value: String(stage.cellsOverlay ? stage.cellColumns : 0)),
            .data("composite-rows", value: String(stage.cellsOverlay ? stage.cellRows : 0)),
            .data("composite-count", value: String(stage.spec.layout.slotCount)),
            .data("composite-w", value: String(stage.spec.contribution.width)),
            .data("composite-h", value: String(stage.spec.contribution.height)),
            .data("composite-frames", value: String(stage.spec.contribution.frames)),
            .data("composite-format", value: stage.spec.contribution.format.rawValue),
            .data("composite-frame-rate", value: String(stage.spec.frameRate)),
            .data("composite-owners", value: stage.showsOwners ? "true" : "false")
        ) {
            div(.class("composite-frame"), .custom(name: "style", value: stage.styleProperties)) {
                canvas(.class("composite-canvas js-composite-canvas"), .ariaLabel("Class composite")) {}
                if stage.cellsOverlay {
                    div(.class("composite-slots composite-slots--overlay js-composite-slots")) {}
                }
            }
            if !stage.cellsOverlay {
                div(
                    .class("composite-slots composite-slots--strip js-composite-slots"),
                    .custom(name: "style", value: stage.styleProperties)
                ) {}
            }
            if stage.isAnimated {
                div(.class("toolbar")) {
                    button(.class("btn action-btn js-composite-play"), .type(.button), .custom(name: "aria-pressed", value: "false")) {
                        "Pause"
                    }
                    " "
                    label(.class("visually-hidden"), .for("composite-frame")) { "Frame" }
                    input(
                        .id("composite-frame"), .class("composite-scrub js-composite-frame"), .type(.range),
                        .custom(name: "min", value: "0"), .custom(name: "max", value: "0"), .value("0"))
                }
            }
            if stage.snapshotURL != nil {
                p(.class("section-note js-composite-progress"), .custom(name: "role", value: "status")) {
                    stage.initialProgress
                }
            }
        }
        .attributes(.data("composite-url", value: stage.snapshotURL ?? ""), when: stage.snapshotURL != nil)
        .attributes(.data("composite-pixels", value: stage.pixels ?? ""), when: stage.pixels != nil)
        .attributes(.data("composite-state", value: stage.pixelsState), when: stage.pixels != nil)
    }
}
