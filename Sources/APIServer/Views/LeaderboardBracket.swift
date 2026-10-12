// APIServer/Views/LeaderboardBracket.swift
//
// One tournament's rounds as columns of match cards. It reads only the
// tournament, so whether names show is the tournament's own `showsNames`,
// never the viewer's role: Present mode builds every tournament without names,
// for staff as well. A bird needs the avatar sprite, which the page renders
// once.
//
// The round labels are h3 under the leaderboard page's h2, and h2 under
// Present mode's h1 (`roundLabelsAreH2`), so the heading levels never skip.
// They are styled by class only, so the level changes nothing on screen.

import Elementary

struct LeaderboardBracket: HTML {
    let tournament: TournamentPresentation
    /// True in Present mode, whose page heading is the h1 directly above.
    var roundLabelsAreH2 = false

    var body: some HTML {
        div(.class("table-scroll"), .role("region"), .ariaLabel("Bracket"), .custom(name: "tabindex", value: "0")) {
            div(.class("bracket"), .role("list")) {
                for round in tournament.rounds {
                    div(.class("bracket-round"), .role("listitem")) {
                        if roundLabelsAreH2 {
                            h2(.class("bracket-round-label")) { round.label }
                        } else {
                            h3(.class("bracket-round-label")) { round.label }
                        }
                        for match in round.matches {
                            BracketMatch(match: match, roundLabel: round.label, showsNames: tournament.showsNames)
                        }
                    }
                }
            }
        }
    }
}

/// One match card: the home line, then the away line or a bye.
private struct BracketMatch: HTML {
    let match: TournamentMatchPresentation
    let roundLabel: String
    let showsNames: Bool

    var body: some HTML {
        div(.class("bracket-match card"), .role("group"), .ariaLabel("\(roundLabel) match")) {
            BracketEntrant(entrant: match.home, won: match.homeWon, isLive: match.isLive, showsNames: showsNames)
            if match.hasAway {
                BracketEntrant(entrant: match.away, won: match.awayWon, isLive: match.isLive, showsNames: showsNames)
            } else {
                div(.class("bracket-entrant text-muted")) { "bye" }
            }
        }
    }
}

/// One entrant's line. A missing entrant draws as an empty line, as the
/// template it replaces did.
private struct BracketEntrant: HTML {
    let entrant: TournamentEntrantPresentation?
    let won: Bool
    let isLive: Bool
    let showsNames: Bool

    private var isViewer: Bool { entrant?.isViewer ?? false }

    var body: some HTML {
        div(.class("bracket-entrant")) {
            if let entrant, entrant.hasAvatar, let avatar = entrant.avatar {
                Avatar(avatar: avatar)
                " "
            }
            span(.dataFlag("avatar-handle")) { entrant?.handle ?? "" }
            if isViewer {
                " "
                span(.class("you-pill")) { "You" }
            }
            if showsNames {
                " "
                span(.class("text-muted")) { "· \(entrant?.name ?? "")" }
            }
            if won {
                " "
                span(.class("tier tier-open")) { "won" }
            }
            if isLive {
                " "
                span(.class("tier tier-preview")) { "live" }
            }
        }
        .attributes(.class("bracket-entrant--you"), when: isViewer)
        .attributes(.class("bracket-entrant--won"), when: won)
    }
}
