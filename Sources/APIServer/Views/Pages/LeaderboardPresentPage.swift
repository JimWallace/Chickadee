// APIServer/Views/Pages/LeaderboardPresentPage.swift
//
// GET /testsetups/:id/leaderboard?present=1: the leaderboard for a projector
// (docs/class-activities.md). Course staff only. Dark and without site chrome
// (`PresentLayout`). The results region refreshes from
// `?present=1&fragment=present` (`LeaderboardPresentBody`) while anything on
// it can still change. A browser-graded tournament adds the projector arena's
// "Play matches" control (`Public/tournament-arena.js`).

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
                    if board.arenaSetupID != nil {
                        " "
                        button(.class("btn action-btn"), .type(.button), .dataFlag("arena-play")) { "Play matches" }
                        " "
                        span(.class("text-quiet"), .role("status"), .dataFlag("arena-status")) {}
                    }
                }
                .attributes(.data("arena-setup-id", value: board.arenaSetupID ?? ""), when: board.arenaSetupID != nil)
                div(.id("present-results")) {
                    LeaderboardPresentBody(board: board)
                }
                .attributes(
                    .data("poll-swap", value: "region"), .data("poll-url", value: board.pollURL),
                    .data("poll-interval", value: "5000"), when: board.pollsLive)
            }
            if let arenaSetupID = board.arenaSetupID {
                // The projector arena plays a browser-graded tournament here,
                // on the stack a student's submit uses (tournament-arena.js).
                for path in BrowserGradingScripts.beforeRunner {
                    script(.src(page.asset(path))) {}
                }
                script(
                    .src(page.asset("/browser-runner.js")), .data("setup-id", value: arenaSetupID),
                    .data("grading-mode", value: "browser")
                ) {}
                script(.src(page.asset("/tournament-arena.js"))) {}
            }
        }
    }
}
