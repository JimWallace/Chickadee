// Tests/APITests/Gamification/SpriteInlineMarkupTests.swift
//
// A page inlines each sprite with its comments and the whitespace between
// tags removed (`Application.inlineMarkup`), about 14.6 KB less on every
// signed-in page. These tests pin that nothing a page or the tab icon reads
// changes: every symbol survives with the same id, viewBox and drawing, and
// the tab icon renderer draws the same bytes from the inlined avatar sprite
// as from the file.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct SpriteInlineMarkupTests {
    private static func contents(of path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// Each symbol's id, viewBox and drawing with all whitespace removed.
    private static func symbols(in sprite: String) -> [String: String] {
        var found: [String: String] = [:]
        for match in sprite.matches(of: /<symbol id="([^"]+)" viewBox="([^"]+)">(.*?)<\/symbol>/.dotMatchesNewlines()) {
            found[String(match.1)] = String(match.2) + "|" + String(match.3).filter { !$0.isWhitespace }
        }
        return found
    }

    @Test(arguments: StaticSprite.allCases)
    func inliningKeepsEverySymbolAndDropsOnlyCommentsAndWhitespace(sprite: StaticSprite) throws {
        let file = try Self.contents(of: "Resources/Sprites/\(sprite.rawValue)")
        let inlined = Application.inlineMarkup(file)
        #expect(file.contains("<!--"))
        #expect(!inlined.contains("<!--"))
        #expect(!inlined.contains(">\n"))
        #expect(inlined.hasPrefix("<svg"))
        #expect(inlined.hasSuffix("</svg>"))
        #expect(inlined.utf8.count < file.utf8.count)
        let symbols = Self.symbols(in: file)
        #expect(!symbols.isEmpty)
        #expect(Self.symbols(in: inlined) == symbols)
    }

    @Test func inliningDropsCommentsAndInterTagWhitespaceOnly() {
        #expect(
            Application.inlineMarkup("  <!-- a -->\n<svg>\n  <!-- b\n -->\n  <g/>  x <g/>\n</svg>\n")
                == "<svg><g/>  x <g/></svg>")
        #expect(Application.inlineMarkup("<a> <!-- open") == "<a> <!-- open")
        #expect(Application.inlineMarkup("<!---->") == "")
        #expect(Application.inlineMarkup("") == "")
    }

    @Test func theTabIconDrawsTheSameFromTheInlinedAvatarSprite() throws {
        let file = try Self.contents(of: "Resources/Sprites/avatar-sprite.svg")
        let stylesheet = try Self.contents(of: "Public/styles.css")
        let fromFile = try AvatarIconRenderer(sprite: file, stylesheet: stylesheet)
        let fromInlined = try AvatarIconRenderer(sprite: Application.inlineMarkup(file), stylesheet: stylesheet)
        for cap in AvatarCap.allCases {
            for accessory in AvatarAccessory.allCases {
                let spec = AvatarSpec(
                    cap: cap, wing: .barred, expression: .chirp, accessory: accessory,
                    accent: .honey, backdrop: .sky, tuft: .crest)
                #expect(fromInlined.svg(for: spec) == fromFile.svg(for: spec))
            }
        }
    }
}
