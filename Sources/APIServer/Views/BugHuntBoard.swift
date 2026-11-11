// APIServer/Views/BugHuntBoard.swift
//
// A bug hunt's board (docs/bug-hunt-code-map.md): the share the class has
// covered, and, when the activity carries code, the code with each item's
// lines lit once it is covered. The projector and the staff leaderboard page
// render this one struct, inside their polled regions, so it refreshes with
// them and needs no script of its own.

import Core
import Elementary

struct BugHuntBoard: HTML {
    let hunt: BugHuntPresentation

    var body: some HTML {
        div(.class("bug-hunt")) {
            if !hunt.recordsCoverage {
                FlashBanner(.warning) { "The starter notebook has no contribution slots, so no test is counted." }
            }
            div(.class("bug-hunt-share")) {
                span(.class("score-figure")) { hunt.percentText }
                " "
                span(.class("bug-hunt-count")) { "\(hunt.countText) covered" }
            }
            if hunt.showsCode {
                // The diff listing, one gutter: a covered line reads as an
                // added one (docs/ui-design.md, `.diff-table`).
                table(.class("diff-table"), .ariaLabel("Code covered by the class")) {
                    tbody {
                        for line in hunt.lines {
                            tr(.class(Self.rowClass(line.state))) {
                                td(.class("diff-gutter")) {
                                    "\(line.number)"
                                    if let word = Self.stateWord(line.state) {
                                        span(.class("visually-hidden")) { " \(word)" }
                                    }
                                }
                                td(.class("diff-line")) { line.text }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Each state's row class, written out so every class name is a literal.
    private static func rowClass(_ state: BugHuntLineState) -> String {
        switch state {
        case .lit: return "diff-added"
        case .partial: return "diff-partial"
        case .dark: return "diff-uncovered"
        case .plain: return "diff-context"
        }
    }

    /// The state in words, for a screen reader: the colour alone says it to
    /// everyone else.
    private static func stateWord(_ state: BugHuntLineState) -> String? {
        switch state {
        case .lit: return "covered"
        case .partial: return "partly covered"
        case .dark: return "not covered"
        case .plain: return nil
        }
    }
}
