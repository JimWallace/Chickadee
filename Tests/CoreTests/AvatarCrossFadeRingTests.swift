// Tests/CoreTests/AvatarCrossFadeRingTests.swift
//
// The cross-fade ring (docs/achievement-rewards.md, decision 4): eight flat
// steps from blue on the left to red on the right, the Cross-fade pattern of
// "The Class Paints a Picture". Every step holds the term-ring contrast floors,
// measured on the real stylesheet tokens: at least 1.45:1 against each light
// backdrop and 1.8:1 against each dark one. The ramp runs blue to red: red
// rises and blue falls from step to step, as `x*4` and `236 - x*4` do.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@Suite struct AvatarCrossFadeRingTests {

    private static let lightFloor = 1.45
    private static let darkFloor = 1.8

    private static func contents(of path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every `#RRGGBB` value declared for `token`, in stylesheet order.
    private static func values(of token: String, in css: String) -> [String] {
        css.components(separatedBy: "\(token):").dropFirst().compactMap { tail in
            let value = tail.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
            return value.hasPrefix("#") && value.count == 7 ? value : nil
        }
    }

    private static func channels(_ hex: String) throws -> (red: Int, green: Int, blue: Int) {
        let digits = try #require(Int(hex.dropFirst(), radix: 16))
        return ((digits >> 16) & 0xFF, (digits >> 8) & 0xFF, digits & 0xFF)
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

    private static func steps(in css: String) throws -> [String] {
        try (1...8).map { step in
            let declared = values(of: "--avatar-crossfade-\(step)", in: css)
            // No dark mirror: a ring is the same in both themes.
            try #require(declared.count == 1, "step \(step) is declared \(declared.count) times")
            return declared[0]
        }
    }

    @Test func theRingIsAppendedAndSpecial() {
        #expect(AvatarBorder.allCases.last == .crossfade)
        #expect(AvatarRing.allCases.last == .crossfade)
        #expect(AvatarBorder.crossfade.ring == .crossfade)
        #expect(AvatarBorder.crossfade.availability == .special)
        #expect(AvatarBorder.crossfade.season == nil)
        #expect(AvatarBorder.crossfade.accent == nil)
        #expect(AvatarBorder.crossfade.displayName == "Cross-fade")
    }

    @Test func thePresentationNamesTheRingSymbol() {
        var spec = AvatarSpec.drawn(fromSeed: 5)
        spec.border = .crossfade
        let drawn = AvatarPresentation(for: spec, size: .standard, accessibility: .decorative, isStaff: false)
        #expect(drawn.ringSymbolRef == "#av-ring-crossfade")
    }

    @Test func everyStepIsVisibleOnEveryBackdrop() throws {
        let css = try Self.contents(of: "Public/styles.css")
        for colour in try Self.steps(in: css) {
            for backdrop in AvatarBackdrop.allCases {
                let values = Self.values(of: "--avatar-back-\(backdrop.rawValue)", in: css)
                try #require(values.count == 3, "\(backdrop) has \(values.count) values")
                let light = try Self.contrast(colour, values[0])
                let dark = try Self.contrast(colour, values[1])
                #expect(light >= Self.lightFloor, "\(colour) on light \(backdrop): \(light)")
                #expect(dark >= Self.darkFloor, "\(colour) on dark \(backdrop): \(dark)")
            }
        }
    }

    /// The ramp is the activity's: red never falls and blue never rises.
    @Test func theRampRunsBlueToRed() throws {
        let colours = try Self.steps(in: Self.contents(of: "Public/styles.css")).map(Self.channels)
        for (left, right) in zip(colours, colours.dropFirst()) {
            #expect(right.red >= left.red)
            #expect(right.blue <= left.blue)
        }
        let first = try #require(colours.first)
        let last = try #require(colours.last)
        #expect(first.blue > first.red)
        #expect(last.red > last.blue)
    }

    /// Two segments per step, one above and one below, and every class the
    /// symbol uses is a step class with a rule.
    @Test func theSymbolIsTheEightSteps() throws {
        let sprite = try Self.contents(of: "Resources/Sprites/avatar-sprite.svg")
        let css = try Self.contents(of: "Public/styles.css")
        let start = try #require(sprite.range(of: #"<symbol id="av-ring-crossfade""#))
        let end = try #require(sprite.range(of: "</symbol>", range: start.upperBound..<sprite.endIndex))
        let classes = sprite[start.upperBound..<end.lowerBound].components(separatedBy: "class=\"").dropFirst()
            .map { String($0.prefix { $0 != "\"" }) }
        let expected = (1...8).flatMap { ["av-crossfade-\($0)", "av-crossfade-\($0)"] }
        #expect(classes == expected)
        for step in 1...8 {
            #expect(css.contains(".av-crossfade-\(step) {"), "step \(step) has no rule")
        }
    }

    @Test func noStepIsTheStaffColour() throws {
        let css = try Self.contents(of: "Public/styles.css")
        let staff = try #require(Self.values(of: "--avatar-staff-ring", in: css).first)
        #expect(try !Self.steps(in: css).contains(staff))
    }
}
