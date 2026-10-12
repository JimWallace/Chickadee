// APIServer/Views/LeaderboardList.swift
//
// The ranked list shared by the round robin standings and the tests half of a
// tests-and-code activity. It reads only its `LeaderboardListContext`, never
// the page. The metric list keeps its own markup in `LeaderboardBody`, because
// its staff rows carry extra actions. A row's bird needs the avatar sprite,
// which the page renders once.

import Elementary

struct LeaderboardList<Row: LeaderboardListRow>: HTML {
    let list: LeaderboardListContext<Row>

    var body: some HTML {
        table(.class("results-table section-items"), .id(list.tableID)) {
            colgroup {
                col(.class("leaderboard-rank"))
                col(.class("section-items-tile"))
                col()
                col(.class("section-items-status"))
            }
            thead(.class("visually-hidden")) {
                tr {
                    th(.custom(name: "scope", value: "col")) { "Rank" }
                    th(.custom(name: "scope", value: "col")) { "Bird" }
                    th(.custom(name: "scope", value: "col")) { "Student" }
                    th(.custom(name: "scope", value: "col")) { list.valueLabel }
                }
            }
            tbody {
                for item in list.items {
                    if item.isGap {
                        tr(.class("leaderboard-gap")) {
                            td(.custom(name: "colspan", value: "4")) { item.gapLabel }
                        }
                    } else if let row = item.row {
                        LeaderboardListLine(row: row, valueLabel: list.valueLabel, isStaff: list.isStaff)
                    }
                }
            }
        }
    }
}

/// One ranked line: the disc, the bird, the handle and details, the value.
private struct LeaderboardListLine<Row: LeaderboardListRow>: HTML {
    let row: Row
    let valueLabel: String
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
                div(.class("item-details")) {
                    if isStaff {
                        "\(row.name) · "
                    }
                    row.detailsText
                }
            }
            td(.class("item-status item-grade")) {
                row.valueText
                div(.class("item-details"), .ariaHidden) { valueLabel }
            }
        }
        .attributes(.class("leaderboard-row--you"), when: row.isViewer)
    }
}
