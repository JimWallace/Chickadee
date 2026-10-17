// APIServer/Views/NotebookGradedToast.swift
//
// The graded toast on the notebook page (notebook views NB5, design frame
// 18f). When an attempt finishes grading while the student is still in the
// editor, notebook-graded.js fills in the text and shows it. It stays until the
// student closes it.

import Core
import Elementary

struct NotebookGradedToast: HTML {
    /// The viewer's bird, or nil for no bird.
    let bird: AvatarPresentation?

    var body: some HTML {
        div(.id("nb-graded"), .class("nb-graded"), .role("status"), .hidden) {
            if let bird {
                // Decorative: the text says the result. At 100% three stars
                // appear around the bird, and it hops once.
                div(.class("nb-graded-bird"), .ariaHidden) {
                    Avatar(avatar: bird)
                    span(.class("nb-graded-star")) { "✦" }
                    span(.class("nb-graded-star")) { "✦" }
                    span(.class("nb-graded-star")) { "✦" }
                }
            }
            div(.class("nb-graded-text")) {
                // notebook-graded.js writes these three lines.
                p(.class("outline-caption js-nb-graded-caption")) {}
                p(.class("nb-graded-grade js-nb-graded-grade")) {}
                p(.class("card-meta js-nb-graded-summary")) {}
                div(.class("toolbar")) {
                    a(.class("btn btn-primary"), .id("nb-graded-results"), .href("#")) { "See results" }
                    button(.class("btn"), .type(.button), .id("nb-graded-close")) { "Keep editing" }
                }
            }
        }
    }
}
