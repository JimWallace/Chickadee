// APIServer/Views/Pages/LeaderboardPresentPage.swift
//
// GET /testsetups/:id/leaderboard?present=1: the leaderboard for a projector
// (docs/class-activities.md). Course staff only. Dark and without site chrome
// (`PresentLayout`). The results region refreshes from
// `?present=1&fragment=present` (`LeaderboardPresentBody`) while anything on
// it can still change.

import Elementary

struct LeaderboardPresentPage: HTML {
    let page: PageRequestContext
    let board: PresentModePresentation

    var body: some HTML {
        PresentLayout(title: "\(board.assignmentTitle) — Leaderboard", page: page) {
            AvatarSprite(page: page)
            main(.class("present"), .id("main-content")) {
                div(.class("toolbar")) {
                    a(.class("btn action-btn"), .href(board.boardURL)) { "Back to leaderboard" }
                    " "
                    button(.class("btn action-btn"), .type(.button), .dataFlag("ck-fullscreen")) { "Full screen" }
                }
                div(.id("present-results")) {
                    LeaderboardPresentBody(board: board)
                }
                .attributes(
                    .data("poll-swap", value: "region"), .data("poll-url", value: board.pollURL),
                    .data("poll-interval", value: "5000"), when: board.pollsLive)
            }
        }
    }
}
