// Tests/CoreTests/AvatarConceptRingTests.swift
//
// The six concept rings (docs/student-wardrobe.md, "Concept rings"): earned,
// lateral, one per lab concept. Their band colours hold the term-ring contrast
// floors, measured on the real stylesheet tokens: at least 1.45:1 against each
// light backdrop and 1.8:1 against each dark one. The lamps, eye, pupil, rope,
// the snake's back pattern and the life ring's white quarters are exempt.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@Suite struct AvatarConceptRingTests {

    private static let conceptRings: [AvatarBorder] = [
        .lifering, .greenlight, .ouroboros, .function, .binary, .pulse,
    ]
    private static let bandTokens = [
        "function", "binary", "pulse", "ouroboros-body", "greenlight-band", "lifering-red", "lifering-rim",
    ]
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

    /// The `class` names a ring's symbol uses, in paint order.
    private static func classes(ofRing ring: String) throws -> [String] {
        let sprite = try contents(of: "Resources/Sprites/avatar-sprite.svg")
        let start = try #require(sprite.range(of: "<symbol id=\"av-ring-\(ring)\""))
        let end = try #require(sprite.range(of: "</symbol>", range: start.upperBound..<sprite.endIndex))
        let symbol = sprite[start.upperBound..<end.lowerBound]
        return symbol.components(separatedBy: "class=\"").dropFirst().map { String($0.prefix { $0 != "\"" }) }
    }

    // MARK: - The cases

    @Test func conceptRingsAreAppendedAfterMaple() throws {
        let maple = try #require(AvatarBorder.allCases.firstIndex(of: .maple))
        #expect(Array(AvatarBorder.allCases[(maple + 1)...].prefix(6)) == Self.conceptRings)
    }

    @Test(arguments: conceptRings)
    func aConceptRingIsEarnedAndLateral(border: AvatarBorder) {
        #expect(border.availability == .earned)
        #expect(border.season == nil)
        #expect(border.accent == nil)
        #expect(border.ring.rawValue == border.rawValue)
    }

    @Test func conceptRingNames() {
        #expect(AvatarBorder.lifering.displayName == "Life ring")
        #expect(AvatarBorder.greenlight.displayName == "Green light")
        #expect(AvatarBorder.ouroboros.displayName == "Ouroboros")
        #expect(AvatarBorder.function.displayName == "Function")
        #expect(AvatarBorder.binary.displayName == "Binary")
        #expect(AvatarBorder.pulse.displayName == "Pulse")
    }

    /// No rule earns a concept ring yet, so each is refused.
    @Test(arguments: conceptRings)
    func aConceptRingIsLocked(border: AvatarBorder) {
        #expect(!AvatarCustomization.isOpen(border.rawValue, for: .border))
        #expect(WardrobeItem(slot: .border, value: border.rawValue) == nil)
    }

    // MARK: - The art

    /// Every class a concept ring's symbol uses is that ring's own, and each
    /// has a fill rule in the stylesheet.
    @Test(arguments: conceptRings)
    func eachSymbolUsesItsOwnStyledClasses(border: AvatarBorder) throws {
        let css = try Self.contents(of: "Public/styles.css")
        let classes = try Self.classes(ofRing: border.rawValue)
        try #require(!classes.isEmpty)
        for name in Set(classes) {
            #expect(name == "av-\(border.rawValue)" || name.hasPrefix("av-\(border.rawValue)-"), "\(name)")
            #expect(css.contains(".\(name) { fill: var(--avatar-\(name.dropFirst(3))); }"), "\(name) has no rule")
        }
    }

    @Test func everyBandColourIsVisibleOnEveryBackdrop() throws {
        let css = try Self.contents(of: "Public/styles.css")
        var light: [String: String] = [:]
        var dark: [String: String] = [:]
        for backdrop in AvatarBackdrop.allCases {
            let declared = Self.values(of: "--avatar-back-\(backdrop.rawValue)", in: css)
            try #require(declared.count == 3, "\(backdrop) has \(declared.count) values")
            light[backdrop.rawValue] = declared[0]
            dark[backdrop.rawValue] = declared[1]
        }
        for band in Self.bandTokens {
            let token = "--avatar-\(band)"
            let declared = Self.values(of: token, in: css)
            // No dark mirror: a ring is the same in both themes.
            try #require(declared.count == 1, "\(token) is declared \(declared.count) times")
            for (name, backdrop) in light {
                let ratio = try Self.contrast(declared[0], backdrop)
                #expect(ratio >= Self.lightFloor, "\(token) on light \(name): \(ratio)")
            }
            for (name, backdrop) in dark {
                let ratio = try Self.contrast(declared[0], backdrop)
                #expect(ratio >= Self.darkFloor, "\(token) on dark \(name): \(ratio)")
            }
        }
    }

    /// The staff ring's colour stays reserved: no concept band uses it.
    @Test func noBandIsTheStaffColour() throws {
        let css = try Self.contents(of: "Public/styles.css")
        let staff = try #require(Self.values(of: "--avatar-staff-ring", in: css).first)
        for band in Self.bandTokens {
            #expect(Self.values(of: "--avatar-\(band)", in: css).first != staff, "\(band)")
        }
    }
}
