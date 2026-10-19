// APIServer/Views/CompositeLabsSection.swift
//
// Every lab's image of a class composite that runs once per lab group
// (docs/lab-groups.md, slice 4c), under the staff leaderboard. One stage per
// lab whose session has ended, each with the lab's name and its progress.

import Elementary

struct CompositeLabsSection: HTML {
    let presentation: CompositeLabsPresentation

    var body: some HTML {
        section(.class("page-section")) {
            h2 { "Every lab's image" }
            p(.class("section-note")) { "A lab's image shows here when its session ends." }
            div(.class("composite-labs")) {
                for (index, lab) in presentation.labs.enumerated() {
                    div(.class("composite-labs-item")) {
                        h3 { lab.name }
                        p(.class("card-meta")) { lab.progressText }
                        CompositeStage(stage: lab.stage, scrubID: "composite-scrub-\(index)")
                    }
                }
            }
        }
    }
}
