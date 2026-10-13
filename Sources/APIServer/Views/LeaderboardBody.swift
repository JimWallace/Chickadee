// APIServer/Views/LeaderboardBody.swift
//
// Everything on the leaderboard that moves. `LeaderboardPage` renders it
// inline, and `GET /testsetups/:id/leaderboard?fragment=body` renders it alone
// as the page's background refresh. Both render this one struct, so the
// refresh cannot drift from what it replaces. The page's fixed chrome stays in
// the page. Why: docs/class-activities.md, "Live-session controls (slice 8)".
// A bird needs the avatar sprite, which the page renders once.

import Elementary

struct LeaderboardBody: HTML {
    let board: LeaderboardPresentation

    var body: some HTML {
        if board.hasWindow, let window = board.window {
            div(.class("chip-row")) {
                span(.class("tier")) {
                    "\(window.label) "
                    span(.class("js-relative-time"), .data("iso", value: window.boundaryISO)) {
                        window.boundaryText
                    }
                }
                .attributes(.class("tier-open"), when: window.isOpen)
            }
        }
        if board.hasYou, let you = board.you {
            ViewerStandingCard(you: you)
        }
        if board.showsMetricBoard && board.isStaff {
            p(.class("section-note")) { board.staffSummary }
        }
        if board.hasHill {
            if let champion = board.champion {
                HillCard(champion: champion, isStaff: board.isStaff)
            } else {
                p(.class("text-muted")) { "No student holds the hill yet." }
            }
        }
        if board.showsBracket {
            if board.hasTournament, let tournament = board.tournament {
                p(.class("text-muted")) { tournament.statusText }
                if tournament.hasWinner, let winner = tournament.winner {
                    WinnerCard(winner: winner, isStaff: board.isStaff)
                }
                LeaderboardBracket(tournament: tournament)
            } else {
                p(.class("empty")) { "No tournament has been run yet." }
            }
        } else if board.showsUnion {
            if board.hasUnion, let union = board.union {
                UnionBoard(board: board, union: union)
            } else {
                p(.class("empty")) { "No student has submitted yet." }
            }
        } else if board.showsComposite {
            if let stage = board.compositeStage {
                CompositeStage(stage: stage)
            }
        } else if board.showsStandings {
            if board.standings.isEmpty {
                p(.class("empty")) { "No submission has played a match yet." }
            } else {
                LeaderboardList(list: board.standingList)
                MoreLink(board: board, total: board.rankedCount, shown: board.standingList.items.count)
            }
        } else if board.rows.isEmpty {
            p(.class("empty")) { "No submission has reported a ranking metric yet." }
        } else {
            MetricTable(board: board)
            MoreLink(board: board, total: board.rankedCount, shown: board.displayItems.count)
        }
    }
}

/// The way between a student's window of the list and the whole of it.
/// `total` is the count the "Show all" button names; `shown` is the lines
/// the list drew.
private struct MoreLink: HTML {
    let board: LeaderboardPresentation
    let total: Int
    let shown: Int

    var body: some HTML {
        if board.showingAll {
            p(.class("leaderboard-more")) { a(.class("btn"), .href(board.boardURL)) { "Show my standing" } }
        } else if total > shown {
            p(.class("leaderboard-more")) { a(.class("btn"), .href(board.allURL)) { "Show all \(total)" } }
        }
    }
}

/// The viewer's card at the top of the page.
private struct ViewerStandingCard: HTML {
    let you: ViewerStanding

    var body: some HTML {
        section(.class("you-card card"), .ariaLabel("Your standing")) {
            Avatar(avatar: you.avatar)
            div(.class("you-card-who")) {
                div(.class("you-card-name")) {
                    if you.hasHandle {
                        span(.dataFlag("avatar-handle")) { you.handle }
                        " "
                    }
                    span(.class("you-pill")) { "You" }
                }
                if you.isRanked {
                    div(.class("you-card-rank")) {
                        "\(you.rankHeadline) "
                        small { you.ofText }
                    }
                } else {
                    div(.class("you-card-rank")) { you.rankHeadline }
                    p(.class("section-note")) { a(.href(you.submitURL)) { "Submit to get on the board." } }
                }
                if you.hasHandle {
                    p(.class("section-note")) { you.privacyLine }
                }
            }
            if you.isRanked {
                dl(.class("you-card-stats")) {
                    dt { you.bestLabel }
                    dd {
                        you.bestText
                        if you.hasBestAt {
                            " "
                            span(.class("text-muted")) {
                                "· "
                                span(.class("js-relative-time"), .data("iso", value: you.bestAtISO)) {
                                    you.bestAtText
                                }
                            }
                        }
                    }
                    if you.hasNextPlace {
                        dt { "Next place" }
                        dd { you.nextPlaceText }
                    }
                }
            }
        }
    }
}

/// The hill's holder, on a king-of-the-hill activity.
private struct HillCard: HTML {
    let champion: ChampionPresentation
    let isStaff: Bool

    var body: some HTML {
        section(.class("champion-card card"), .ariaLabel("Holder of the hill")) {
            Avatar(avatar: champion.avatar)
            div(.class("you-card-who")) {
                div(.class("you-card-kicker")) { "Holds the hill" }
                div(.class("you-card-name")) {
                    span(.dataFlag("avatar-handle")) { champion.handle }
                    if champion.isViewer {
                        " "
                        span(.class("you-pill")) { "You" }
                    }
                    if isStaff {
                        " "
                        span(.class("text-muted")) { "· \(champion.name)" }
                    }
                }
                p(.class("section-note")) {
                    "Took it "
                    span(.class("js-relative-time"), .data("iso", value: champion.crownedAtISO)) {
                        champion.crownedAtText
                    }
                    " · \(champion.defencesText)"
                }
            }
        }
        .attributes(.class("you-card"), when: champion.isViewer)
    }
}

/// A finished tournament's winner, above the bracket.
private struct WinnerCard: HTML {
    let winner: TournamentEntrantPresentation
    let isStaff: Bool

    var body: some HTML {
        section(.class("champion-card card"), .ariaLabel("Winner")) {
            if let avatar = winner.avatar {
                Avatar(avatar: avatar)
            }
            div(.class("you-card-who")) {
                div(.class("you-card-kicker")) { "Winner" }
                div(.class("you-card-name")) {
                    span(.dataFlag("avatar-handle")) { winner.handle }
                    if winner.isViewer {
                        " "
                        span(.class("you-pill")) { "You" }
                    }
                    if isStaff {
                        " "
                        span(.class("text-muted")) { "· \(winner.name)" }
                    }
                }
            }
        }
        .attributes(.class("you-card"), when: winner.isViewer)
    }
}

/// A tests-and-code activity: the viewer's card, then the tests list, then
/// whose code is holding.
private struct UnionBoard: HTML {
    let board: LeaderboardPresentation
    let union: UnionPresentation

    var body: some HTML {
        if union.hasYou, let you = union.you {
            UnionYouSection(you: you)
        }
        p(.class("text-muted")) { union.summaryText }
        h3(.class("submission-section-heading")) { "Tests" }
        LeaderboardList(list: union.killList)
        MoreLink(board: board, total: union.kills.count, shown: union.killList.items.count)
        h3(.class("submission-section-heading")) { "Code" }
        table(.class("results-table section-items"), .id("leaderboard-code-table")) {
            colgroup {
                col(.class("section-items-tile"))
                col()
            }
            thead(.class("visually-hidden")) {
                tr {
                    th(.custom(name: "scope", value: "col")) { "Bird" }
                    th(.custom(name: "scope", value: "col")) { "Student" }
                }
            }
            tbody {
                for row in union.defences {
                    UnionDefenceLine(row: row, isStaff: board.isStaff)
                }
            }
        }
    }
}

/// The viewer's card above a union activity's lists.
private struct UnionYouSection: HTML {
    let you: UnionYouCard

    var body: some HTML {
        section(.class("you-card card"), .ariaLabel("Your standing")) {
            Avatar(avatar: you.avatar)
            div(.class("you-card-who")) {
                div(.class("you-card-kicker")) { you.kicker }
                div(.class("you-card-rank")) { you.titleText }
                if you.isRanked {
                    p(.class("section-note")) { you.noteText }
                } else {
                    p(.class("section-note")) { a(.href(you.submitURL)) { "Submit to get on the board." } }
                }
                if you.hasHandle {
                    p(.class("section-note")) { you.privacyLine }
                }
            }
        }
    }
}

/// One student's code, by how it has held up.
private struct UnionDefenceLine: HTML {
    let row: UnionDefenceRow
    let isStaff: Bool

    var body: some HTML {
        tr {
            td(.class("item-tile-cell")) { Avatar(avatar: row.avatar) }
            td(.class("item-main")) {
                div(.class("item-title")) {
                    span(.dataFlag("avatar-handle")) { row.handle }
                    if row.isViewer {
                        " "
                        span(.class("you-pill")) { "You" }
                    }
                }
                div(.class("item-details")) {
                    if isStaff {
                        "\(row.name) · "
                    }
                    row.detailsText
                }
            }
        }
        .attributes(.class("leaderboard-row--you"), when: row.isViewer)
    }
}

/// The ranked-by-metric list. Its staff rows carry the login name, the
/// submission count and a link to the best submission.
private struct MetricTable: HTML {
    let board: LeaderboardPresentation

    var body: some HTML {
        table(.class("results-table section-items"), .id("leaderboard-table")) {
            colgroup {
                col(.class("leaderboard-rank"))
                col(.class("section-items-tile"))
                col()
                col(.class("section-items-status"))
                if board.isStaff {
                    col(.class("section-items-count"))
                }
            }
            thead(.class("visually-hidden")) {
                tr {
                    th(.custom(name: "scope", value: "col")) { "Rank" }
                    th(.custom(name: "scope", value: "col")) { "Bird" }
                    th(.custom(name: "scope", value: "col")) { "Student" }
                    th(.custom(name: "scope", value: "col")) { "Metric" }
                    if board.isStaff {
                        th(.custom(name: "scope", value: "col")) { "Actions" }
                    }
                }
            }
            tbody {
                for item in board.displayItems {
                    if item.isGap {
                        tr(.class("leaderboard-gap")) {
                            td(.custom(name: "colspan", value: board.isStaff ? "5" : "4")) { item.gapLabel }
                        }
                    } else if let row = item.row {
                        MetricLine(row: row, isStaff: board.isStaff)
                    }
                }
            }
        }
    }
}

/// One line of the metric list.
private struct MetricLine: HTML {
    let row: LeaderboardRow
    let isStaff: Bool

    var body: some HTML {
        tr {
            td(.class("leaderboard-rank")) {
                span(.class("rank-disc"), .data("rank-tier", value: row.rankTier)) { row.rankText }
            }
            td(.class("item-tile-cell")) { Avatar(avatar: row.avatar) }
            td(.class("item-main")) {
                div(.class("item-title")) {
                    span(.dataFlag("avatar-handle")) { row.handle }
                    if row.isViewer {
                        " "
                        span(.class("you-pill")) { "You" }
                    }
                }
                if isStaff {
                    div(.class("item-details")) {
                        "\(row.name) · "
                        code { row.username }
                        " · \(row.submissionCountText) · best "
                        span(.class("js-relative-time"), .data("iso", value: row.bestAtISO)) { row.bestAtText }
                    }
                } else if row.hasTieNote {
                    div(.class("item-details")) { row.tieNote }
                }
            }
            td(.class("item-status item-grade")) { row.metricText }
            if isStaff {
                td(.class("item-actions-td")) {
                    div(.class("assignment-actions-cell")) {
                        a(
                            .class("btn action-btn action-btn-icon"), .href(row.bestSubmissionURL),
                            .title("View best submission"), .ariaLabel("View best submission of \(row.handle)")
                        ) {
                            Icon("i-eye")
                        }
                    }
                }
            }
        }
        .attributes(.class("leaderboard-row--you"), when: row.isViewer)
    }
}
