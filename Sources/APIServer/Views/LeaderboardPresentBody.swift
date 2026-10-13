// APIServer/Views/LeaderboardPresentBody.swift
//
// The projected leaderboard's moving part. `LeaderboardPresentPage` renders it
// inline, and `GET /testsetups/:id/leaderboard?present=1&fragment=present`
// renders it alone as the page's background refresh. Both render this one
// struct, so the refresh cannot drift from what it replaces. A bird needs the
// avatar sprite, which the page renders once.

import Core
import Elementary

struct LeaderboardPresentBody: HTML {
    let board: PresentModePresentation

    var body: some HTML {
        header(.class("present-header")) {
            div {
                div(.class("present-kicker")) { "\(board.courseCode) · \(board.assignmentTitle)" }
                h1(.class("present-title")) { board.title }
            }
            if board.hasWindow, let window = board.window {
                div(.class("present-clock")) {
                    span(.class("present-clock-label")) { window.label }
                    " "
                    span(.class("present-clock-time js-relative-time"), .data("iso", value: window.boundaryISO)) {
                        window.boundaryText
                    }
                }
            }
            if board.hasProgress {
                div(.class("present-clock")) {
                    span(.class("present-clock-label")) { board.progressLabel }
                    " "
                    span(.class("present-clock-time")) { board.progressValue }
                }
            }
        }
        if let stage = board.compositeStage {
            div(.class("present-composite")) {
                CompositeStage(stage: stage)
            }
        } else if board.showsBracket {
            if board.hasWinner, let avatar = board.winnerAvatar {
                PresentCard(label: "Winner", kicker: "Winner", handle: board.winnerHandle, avatar: avatar)
            }
            if board.hasTournament, let tournament = board.tournament {
                div(.class("present-bracket")) {
                    LeaderboardBracket(tournament: tournament, roundLabelsAreH2: true)
                }
            } else {
                p(.class("empty")) { "No tournament has been run yet." }
            }
        } else {
            if board.hasChampion && !board.championOnPodium, let avatar = board.championAvatar {
                PresentCard(
                    label: "Holder of the hill", kicker: "Holds the hill", handle: board.championHandle,
                    avatar: avatar)
            }
            if board.hasPodium {
                div(.class("present-stage")) {
                    div(.class("podium")) {
                        for place in board.podium {
                            PodiumPlace(place: place)
                        }
                    }
                    if !board.rest.isEmpty {
                        div(.class("present-rows")) {
                            for place in board.rest {
                                PresentRow(place: place)
                            }
                        }
                    }
                }
            } else {
                p(.class("empty")) { "Nobody is on the board yet." }
            }
        }
        footer(.class("present-footer")) {
            if board.compositeStage == nil {
                strong { "\(board.showsBracket ? board.entrantCount : board.rankedCount) on the board" }
                " "
                span { "Find yourself by your bird and handle on your own Leaderboard page" }
            } else {
                span { "Your own tile is on your submission page" }
            }
            if board.pollsLive {
                " "
                span(.class("tier tier-preview")) { "Live" }
            }
        }
    }
}

/// The tournament's winner or the hill's holder, on a card above the stage.
private struct PresentCard: HTML {
    let label: String
    let kicker: String
    let handle: String
    let avatar: AvatarPresentation

    var body: some HTML {
        section(.class("champion-card card"), .ariaLabel(label)) {
            Avatar(avatar: avatar)
            div(.class("you-card-who")) {
                div(.class("you-card-kicker")) { kicker }
                div(.class("you-card-name"), .dataFlag("avatar-handle")) { handle }
            }
        }
    }
}

/// One of the three places on the podium.
private struct PodiumPlace: HTML {
    let place: PresentPlace

    var body: some HTML {
        div(
            .class("podium-place"), .data("rank-tier", value: place.rankTier),
            .ariaLabel("Place \(place.rankText)")
        ) {
            if place.isChampion {
                div(.class("podium-kicker")) { "Holds the hill" }
            }
            Avatar(avatar: place.avatar)
            div(.class("podium-handle"), .dataFlag("avatar-handle")) { place.handle }
            div(.class("podium-value")) { place.valueText }
            div(.class("podium-plinth")) {
                span(.class("rank-disc"), .data("rank-tier", value: place.rankTier)) { place.rankText }
            }
        }
    }
}

/// One of places four to ten, in the list beside the podium.
private struct PresentRow: HTML {
    let place: PresentPlace

    var body: some HTML {
        div(.class("present-row")) {
            span(.class("rank-disc"), .data("rank-tier", value: place.rankTier)) { place.rankText }
            " "
            Avatar(avatar: place.avatar)
            " "
            span(.class("present-row-handle"), .dataFlag("avatar-handle")) { place.handle }
            " "
            span(.class("present-row-value")) { place.valueText }
        }
    }
}
