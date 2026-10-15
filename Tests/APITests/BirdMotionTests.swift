// Tests/APITests/BirdMotionTests.swift
//
// The user's own bird moves a little (#2589): a lean on hover or focus, a
// slow breath on the account page, and a hop while that bird is pressed. It
// is CSS only, and all of it sits behind
// `prefers-reduced-motion: no-preference`.

import ChickadeeTestSupport
import Foundation
import Testing

@Suite struct BirdMotionTests {

    private static let guardOpen = "@media (prefers-reduced-motion: no-preference) {"

    /// The text inside each reduced-motion guard in `css`, found by matching
    /// braces, so a comment or a nested rule cannot end a block early.
    private static func guardedBlocks(in css: String) -> [Substring] {
        var blocks: [Substring] = []
        var searchStart = css.startIndex
        while let open = css.range(of: guardOpen, range: searchStart..<css.endIndex) {
            var depth = 1
            var index = open.upperBound
            while index < css.endIndex, depth > 0 {
                if css[index] == "{" { depth += 1 }
                if css[index] == "}" { depth -= 1 }
                index = css.index(after: index)
            }
            blocks.append(css[open.upperBound..<index])
            searchStart = index
        }
        return blocks
    }

    private static func stylesheet() throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent("Public/styles.css"), encoding: .utf8)
    }

    /// Each declaration that moves the user's own bird is inside a guard, and
    /// nowhere outside one, so a reader who asked for less motion sees a still
    /// bird.
    @Test(arguments: [
        "animation: bird-breathe",
        "transform: rotate(-8deg)",
        "transform: translateY(-.375rem) scale(1.05)",
    ])
    func theMotionIsOnlyForReadersWhoDidNotAskForLess(declaration: String) throws {
        let css = try Self.stylesheet()
        let blocks = Self.guardedBlocks(in: css)
        let inside = blocks.reduce(0) { $0 + $1.components(separatedBy: declaration).count - 1 }
        let everywhere = css.components(separatedBy: declaration).count - 1
        #expect(inside == 1, "\(declaration) is not in exactly one guarded rule")
        #expect(everywhere == inside, "\(declaration) appears outside the reduced-motion guard")
    }

    /// Only the user's own bird moves: the guarded rules name the nav, the
    /// result page and the account card, and never a bare `.avatar`.
    @Test func onlyTheUsersOwnBirdMoves() throws {
        let block = try #require(
            Self.guardedBlocks(in: try Self.stylesheet()).first { $0.contains("bird-breathe") })
        for selector in [".nav-username", ".submission-bird", ".bird-card-hero"] {
            #expect(block.contains(selector), "\(selector) does not move")
        }
        for line in block.split(separator: "\n") where line.contains(".avatar") {
            #expect(
                [".nav-username", ".submission-bird", ".bird-card-hero"].contains { line.contains($0) },
                "a rule moves a bird that is not the user's own: \(line)")
        }
    }
}
