// Tests/CoreTests/AvatarTermRingTests.swift
//
// The term rings (snowflake, blossom, maple) are colour ramps
// (docs/student-wardrobe.md, "Rings"): eight flat steps per term, mirrored
// left and right, from light at the top to deep at the bottom. Every step must
// stay visible on every backdrop: at least 1.45:1 against each light backdrop
// and 1.8:1 against each dark one, measured on the real stylesheet tokens.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@Suite struct AvatarTermRingTests {

    private static let terms = ["winter", "spring", "fall"]
    private static let lightFloor = 1.45
    private static let darkFloor = 1.8

    private static func contents(of path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every `#RRGGBB` value declared for `token`, in stylesheet order: the
    /// light value first, then the dark ones (none for a ring token).
    private static func values(of token: String, in css: String) -> [String] {
        css.components(separatedBy: "\(token):").dropFirst().compactMap { tail in
            let value = tail.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
            return value.hasPrefix("#") && value.count == 7 ? value : nil
        }
    }

    /// WCAG relative luminance of `#RRGGBB`.
    private static func luminance(_ hex: String) throws -> Double {
        let digits = try #require(Int(hex.dropFirst(), radix: 16))
        func channel(_ shift: Int) -> Double {
            let value = Double((digits >> shift) & 0xFF) / 255
            return value <= 0.039_28 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    private static func contrast(_ first: String, _ second: String) throws -> Double {
        let (a, b) = (try luminance(first), try luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    @Test func everyStepIsVisibleOnEveryBackdrop() throws {
        let css = try Self.contents(of: "Public/styles.css")
        var light: [String: String] = [:]
        var dark: [String: String] = [:]
        for backdrop in AvatarBackdrop.allCases {
            let declared = Self.values(of: "--avatar-back-\(backdrop.rawValue)", in: css)
            // The light value, then the two dark blocks (the media query and
            // the explicit dark theme).
            try #require(declared.count == 3, "\(backdrop) has \(declared.count) values")
            light[backdrop.rawValue] = declared[0]
            dark[backdrop.rawValue] = declared[1]
        }
        for term in Self.terms {
            for step in 1...8 {
                let token = "--avatar-\(term)-\(step)"
                let declared = Self.values(of: token, in: css)
                // No dark mirror: a ring is the same in both themes.
                try #require(declared.count == 1, "\(token) is declared \(declared.count) times")
                let colour = declared[0]
                for (name, backdrop) in light {
                    let ratio = try Self.contrast(colour, backdrop)
                    #expect(ratio >= Self.lightFloor, "\(token) on light \(name): \(ratio)")
                }
                for (name, backdrop) in dark {
                    let ratio = try Self.contrast(colour, backdrop)
                    #expect(ratio >= Self.darkFloor, "\(token) on dark \(name): \(ratio)")
                }
            }
        }
    }

    /// Each term ring's symbol is its own ramp: two segments per step, one on
    /// each side, and nothing else (no motif, no other colour).
    @Test(arguments: [("snowflake", "winter"), ("blossom", "spring"), ("maple", "fall")])
    func eachTermRingIsItsRamp(ring: String, term: String) throws {
        let sprite = try Self.contents(of: "Resources/Sprites/avatar-sprite.svg")
        let start = try #require(sprite.range(of: "<symbol id=\"av-ring-\(ring)\""))
        let end = try #require(sprite.range(of: "</symbol>", range: start.upperBound..<sprite.endIndex))
        let symbol = sprite[start.upperBound..<end.lowerBound]
        let classes = symbol.components(separatedBy: "class=\"").dropFirst().map { $0.prefix { $0 != "\"" } }
        #expect(classes.count == 16)
        for step in 1...8 {
            #expect(classes.filter { $0 == "av-\(term)-\(step)" }.count == 2, "step \(step)")
        }
    }

    @Test func termRingsAreNamedByTheirTerm() {
        #expect(AvatarBorder.snowflake.displayName == "Winter")
        #expect(AvatarBorder.blossom.displayName == "Spring")
        #expect(AvatarBorder.maple.displayName == "Fall")
        #expect(TermSeason.allCases.map(\.startMonthName) == ["January", "May", "September"])
    }
}
