// Tests/APITests/Gamification/AvatarIconRendererTests.swift
//
// The tab icon renderer (docs/student-avatars.md, "The tab icon"), built from
// the real sprite and the real stylesheet.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct AvatarIconRendererTests {
    private static func contents(of path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static let sprite = (try? contents(of: "Resources/Sprites/avatar-sprite.svg")) ?? ""
    private static let stylesheet = (try? contents(of: "Public/styles.css")) ?? ""

    private func renderer() throws -> AvatarIconRenderer {
        try AvatarIconRenderer(sprite: Self.sprite, stylesheet: Self.stylesheet)
    }

    /// The classes the drawn markup uses, and the classes the style block colours.
    private func classes(in svg: String) -> (used: Set<String>, styled: Set<String>) {
        let body = svg.split(separator: "</style>").last.map(String.init) ?? ""
        let used = Set(body.matches(of: /class="([^"]+)"/).flatMap { $0.1.split(separator: " ").map(String.init) })
        let styled = Set(svg.matches(of: /\.(av-[a-z0-9-]+)\{/).map { String($0.1) })
        return (used, styled)
    }

    @Test func everyColourwayBackdropAndAccessoryRendersFullyResolved() throws {
        let renderer = try renderer()
        for cap in AvatarCap.allCases {
            for backdrop in AvatarBackdrop.allCases {
                for accessory in AvatarAccessory.allCases {
                    let spec = AvatarSpec(
                        cap: cap, wing: .barred, expression: .chirp, accessory: accessory,
                        accent: .honey, backdrop: backdrop, tuft: .crest)
                    let svg = renderer.svg(for: spec)
                    let (used, styled) = classes(in: svg)
                    #expect(!svg.contains("var("), "\(spec) leaves a var() reference")
                    #expect(used.isSubset(of: styled), "\(spec) leaves \(used.subtracting(styled)) unstyled")
                    #expect(used == styled, "\(spec) styles classes it does not draw")
                }
            }
        }
    }

    @Test func everyTokenAPresentationCanNameResolvesInTheLightPalette() throws {
        let declared = Set(
            Self.stylesheet[..<(Self.stylesheet.firstRange(of: "@media")?.lowerBound ?? Self.stylesheet.endIndex)]
                .matches(of: /(--avatar-[a-z0-9-]+):/).map { String($0.1) })
        let tokens = AvatarIconRenderer.nameableTokens
        #expect(!tokens.isEmpty)
        #expect(tokens.subtracting(declared).isEmpty, "not declared: \(tokens.subtracting(declared).sorted())")
    }

    @Test func theIconDrawsNoRingAndNoTilt() throws {
        let renderer = try renderer()
        let spec = AvatarSpec(
            cap: .teal, wing: .barred, expression: .bright, accessory: .scarf, accent: .honey,
            backdrop: .sky, tuft: .cowlick, tilt: .left, border: .rainbow)
        let svg = renderer.svg(for: spec)
        #expect(!svg.contains("av-rainbow"))
        #expect(!svg.contains("av-ring"))
        #expect(!svg.contains("av-staff-ring"))
        #expect(!svg.contains("rotate(-9"))
        #expect(svg.hasPrefix(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><style>"#))
        #expect(svg.hasSuffix("</svg>"))
    }

    @Test func theTealBirdReadsItsColoursFromThePalette() throws {
        let spec = AvatarSpec(
            cap: .teal, wing: .barred, expression: .bright, accessory: .scarf, accent: .honey, backdrop: .sky)
        let svg = try renderer().svg(for: spec)
        #expect(svg.contains(".av-backdrop{fill:#D0E5F0}"))
        #expect(svg.contains(".av-cap{fill:#15808C}"))
        #expect(svg.contains(".av-accent{fill:#D79A2B}"))
    }

    @Test func theHouseBirdMatchesItsSnapshot() throws {
        let expected = try Self.contents(of: "Tests/Fixtures/avatar-icon-house.svg")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try renderer().svg(for: AvatarIconKey.houseSpec) == expected)
    }

    @Test func aMissingSymbolIsAStartupError() {
        let sprite = Self.sprite.replacing(#"<symbol id="av-wing-barred""#, with: #"<symbol id="av-wing-gone""#)
        #expect(throws: AvatarIconRendererError.missingSymbol("av-wing-barred")) {
            try AvatarIconRenderer(sprite: sprite, stylesheet: Self.stylesheet)
        }
    }

    @Test func aMissingTokenIsAStartupError() {
        let stylesheet = Self.stylesheet.replacing("--avatar-back-aqua: #CBEAE3;", with: "")
        #expect(throws: AvatarIconRendererError.missingToken("--avatar-back-aqua")) {
            try AvatarIconRenderer(sprite: Self.sprite, stylesheet: stylesheet)
        }
    }

    @Test func aMissingClassRuleIsAStartupError() {
        let stylesheet = Self.stylesheet.replacing(".av-glint { fill: var(--avatar-glint); }", with: "")
        #expect(throws: AvatarIconRendererError.missingClassRule("av-glint")) {
            try AvatarIconRenderer(sprite: Self.sprite, stylesheet: stylesheet)
        }
    }

    @Test func anEmptyStylesheetIsAStartupError() {
        #expect(throws: AvatarIconRendererError.missingPalette) {
            try AvatarIconRenderer(sprite: Self.sprite, stylesheet: "")
        }
    }
}
