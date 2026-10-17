// APIServer/Views/EarnedToast.swift
//
// The Earned toast on the student's own result page
// (docs/result-celebration.md, J2): the bird wearing the item that this page
// load granted, what the item is, how the student earned it, and Wear it and
// Not now. It is the notebook page's graded toast (`NotebookGradedToast`) in
// shape, fixed at the bottom right. earned-toast.js shows it after the
// celebration's pop and announces it. It never closes by itself.
//
// Wear it is an ordinary form: without the script it saves and goes to the
// account page. The script saves in place and points the page bird's layers
// at the `data-wear-*` values, as the account page's live preview does.

import Core
import Elementary

struct EarnedToast: HTML {
    let page: PageRequestContext
    let earned: SubmissionEarnedItem

    /// Written as a custom attribute because SwiftLint bans the style
    /// modifier in views. It holds only a custom property, which the
    /// rendered-page guard allows.
    private var customProperties: String {
        "--earned-ring-start: \(earned.ringStartDegrees)deg"
    }

    var body: some HTML {
        div(
            .id("earned-toast"), .class("nb-graded nb-graded-earned"), .role("status"), .hidden,
            .data("announce", value: earned.announcement), .custom(name: "style", value: customProperties)
        ) {
            // Decorative: the text names the item.
            div(.class("nb-graded-bird"), .ariaHidden) {
                Avatar(avatar: earned.bird)
            }
            div(.class("nb-graded-text")) {
                p(.class("outline-caption")) { span(.class("chip")) { earned.chip } }
                p(.class("nb-graded-grade")) { earned.name }
                p(.class("card-meta")) { earned.howEarned }
                // earned-toast.js writes the announcement here once the
                // toast shows: a live region that appears is not read.
                p(.class("visually-hidden js-earned-live")) {}
                form(
                    .method(.post), .action("/account/avatar"), .class("toolbar js-earned-wear"),
                    .data("wear-ring", value: earned.isRing ? earned.bird.ringSymbolRef : ""),
                    .data("wear-token", value: earned.isRing ? earned.bird.borderToken : ""),
                    .data("wear-face", value: earned.isRing ? "" : earned.bird.expressionSymbolRef)
                ) {
                    CSRFField(token: page.csrfToken)
                    input(.type(.hidden), .name(earned.field), .value(earned.value))
                    button(.class("btn btn-primary"), .type(.submit)) { "Wear it" }
                    button(.class("btn js-earned-close"), .type(.button)) { "Not now" }
                }
            }
        }
        .attributes(.class("is-ring"), when: earned.isRing)
    }
}
