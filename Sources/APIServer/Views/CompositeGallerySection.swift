// APIServer/Views/CompositeGallerySection.swift
//
// Every lab's image of a class composite that runs once per lab group
// (docs/lab-groups.md, slice 4c), under the staff leaderboard. One stage per
// lab whose session has ended, each with the lab's name and its progress.

import Elementary

struct CompositeGallerySection: HTML {
    let gallery: CompositeGalleryPresentation

    var body: some HTML {
        section(.class("page-section")) {
            h3 { "Every lab's image" }
            p(.class("section-note")) { "A lab's image shows here when its session ends." }
            div(.class("composite-gallery")) {
                for (index, lab) in gallery.labs.enumerated() {
                    div(.class("composite-gallery-lab")) {
                        h4 { lab.name }
                        p(.class("text-muted")) { lab.progressText }
                        CompositeStage(stage: lab.stage, scrubID: "composite-scrub-\(index)")
                    }
                }
            }
        }
    }
}
