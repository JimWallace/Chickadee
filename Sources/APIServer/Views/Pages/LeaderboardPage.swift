// APIServer/Views/Pages/LeaderboardPage.swift
//
// GET /testsetups/:id/leaderboard: a class activity's ranking
// (docs/class-activities.md). The fixed chrome is here: the title, the kind
// chip, the staff visibility form and Present link, and the intro. The part
// that moves is `LeaderboardBody`, which refreshes from `?fragment=body` while
// a session window is live.

import Elementary

struct LeaderboardPage: HTML {
    let page: PageRequestContext
    let board: LeaderboardPresentation

    var body: some HTML {
        BaseLayout(title: "\(board.assignmentTitle) — Leaderboard", page: page) {
            if !board.courseLabel.isEmpty {
                p(.class("page-crumb")) { board.courseLabel }
            }
            h1 { board.assignmentTitle }
            AvatarSprite(page: page)
            section(.class("page-section")) {
                div(.class("page-titlebar")) {
                    h2 { "Leaderboard" }
                    div(.class("toolbar")) {
                        span(.class("chip")) { board.kindLabel }
                        if board.isStaff {
                            visibilityForm
                            a(
                                .class("btn action-btn"), .href("\(board.boardURL)?present=1"), .target(.blank),
                                .rel("noopener")
                            ) {
                                Icon("i-slides")
                                " Present"
                            }
                        }
                    }
                }
                intro
                if board.showFilter {
                    div(.class("toolbar toolbar--end section-gap")) {
                        span(.class("filter-group")) {
                            " "
                            label(.class("filter-label"), .for("leaderboard-filter")) { "Filter" }
                            " "
                            input(
                                .id("leaderboard-filter"), .class("form-input filter-input"), .type(.search),
                                .placeholder(board.filterPlaceholder),
                                .data("list-filter", value: "leaderboard-table"),
                                .data("list-filter-empty", value: "Nobody on the board matches this filter."))
                            " "
                        }
                    }
                }
                // The canvas stays outside the polled region: a swap would
                // replace it. It polls its own JSON through table-poll.js.
                if let stage = board.compositeStage {
                    CompositeStage(stage: stage)
                }
                div(.id("activity-results")) {
                    LeaderboardBody(board: board)
                }
                .attributes(
                    .data("poll-swap", value: "region"), .data("poll-url", value: board.pollURL),
                    .data("poll-interval", value: "5000"), when: board.pollsLive
                )
                .attributes(
                    .data("poll-until", value: board.pollUntilISO), when: board.pollsLive && board.hasPollUntil)
            }
            if board.showFilter {
                script(.src(page.asset("/list-filter.js"))) {}
            }
            if board.compositeStage != nil {
                script(.src(page.asset("/class-composite-core.js"))) {}
                script(.src(page.asset("/class-composite.js"))) {}
            }
            if board.pollsLive || board.compositeStage != nil {
                script(.src(page.asset("/table-poll.js"))) {}
            }
        }
    }

    /// Staff show or hide the board from students without leaving it.
    private var visibilityForm: some HTML {
        form(
            .method(.post), .action("/instructor/\(board.assignmentPublicID)/activity"),
            .class("inline-form form-flush")
        ) {
            CSRFField(token: page.csrfToken)
            " "
            input(.type(.hidden), .name("returnTo"), .value(board.boardURL))
            " "
            label(.class("visually-hidden"), .for("leaderboard-visibility")) { "Visibility to students" }
            " "
            span(.class("state-select"), .data("state", value: board.visibleToStudents ? "visible" : "hidden")) {
                " "
                select(
                    .id("leaderboard-visibility"), .name("visibility"), .class("form-input"),
                    .dataFlag("ck-submit-on-change")
                ) {
                    option(.value("visible")) { "Visible to students" }
                        .attributes(.selected, when: board.visibleToStudents)
                    option(.value("hidden")) { "Hidden from students" }
                        .attributes(.selected, when: !board.visibleToStudents)
                }
                " "
            }
        }
    }

    /// One sentence on how this kind of board ranks.
    @HTMLBuilder private var intro: some HTML {
        if board.showsBracket {
            p(.class("section-intro")) {
                "Each match plays the first entrant's frozen submission against the second's. Rounds advance "
                    + "as matches land. Students appear under their class handle."
            }
        } else if board.showsUnion {
            p(.class("section-intro")) {
                "Every student's tests run against every classmate's latest submission. Most faults found first, "
                    + "then most classmates tested; code that is still holding first. Students appear under "
                    + "their class handle."
            }
        } else if board.showsComposite {
            p(.class("section-intro")) {
                "Each student renders one slot of a shared image. The slot holders are listed under it. "
                    + "The image never changes a grade."
            }
        } else if board.showsStandings {
            p(.class("section-intro")) {
                "Highest average match score first, then most wins. Each row is the student's latest "
                    + "submission. Students appear under their class handle."
            }
        } else {
            p(.class("section-intro")) {
                "Highest metric first. A tie goes to the submission that reached it first. Students appear "
                    + "under their class handle."
            }
        }
    }
}
