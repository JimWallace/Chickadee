// Tests/CoreTests/AvatarQuantumCatsRingTests.swift
//
// The Quantum Cats ring (docs/student-wardrobe.md, "Found items"): found, not
// earned. No graded work opens it, the chokepoint refuses it until it is
// unlocked, and its band holds the concept-ring contrast floors, measured on
// the real stylesheet tokens: at least 1.45:1 against each light backdrop and
// 1.8:1 against each dark one. The cat, its eyes and the orbit are exempt.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@Suite struct AvatarQuantumCatsRingTests {

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

    // MARK: - The cases

    @Test func theRingIsAppendedAfterPulse() throws {
        #expect(AvatarBorder.allCases.last == .quantumcats)
        #expect(AvatarRing.allCases.last == .quantumcats)
        #expect(AvatarBorder.quantumcats.ring == .quantumcats)
    }

    @Test func theRingIsFound() {
        #expect(AvatarBorder.quantumcats.availability == .found)
        #expect(AvatarBorder.quantumcats.season == nil)
        #expect(AvatarBorder.quantumcats.accent == nil)
        #expect(AvatarBorder.quantumcats.displayName == "Quantum Cats")
    }

    @Test func theItemIsFoundAndOpensTheRing() throws {
        let item = WardrobeItem.quantumCatsRing
        #expect(item.rawValue == "border.quantumcats")
        #expect(item.isFound)
        #expect(item.slot == .border)
        #expect(item.value == AvatarBorder.quantumcats.rawValue)
        #expect(item.concept == nil)
        #expect(item.displayName == "Quantum Cats")
        #expect(item.howEarned == "by entering the Konami code")
        #expect(item.obtainedVerb == "Found")
        #expect(WardrobeItem.twoToneRing.obtainedVerb == "Earned")
        #expect(WardrobeItem.allCases.filter(\.isFound) == [.quantumCatsRing])
    }

    /// No graded work opens a found item, however much of it there is.
    @Test func noWorkEarnsIt() {
        let graded = (0..<10).map { index in
            WardrobeProgress.Graded(
                assignmentID: "a\(index)", attemptNumber: 1, passCount: 4, totalTests: 4,
                secondsBeforeDue: 7 * 86_400)
        }
        #expect(!WardrobeItem.earned(by: WardrobeProgress(graded: graded)).contains(.quantumCatsRing))
    }

    @Test func theRingIsLockedUntilFound() throws {
        let value = AvatarBorder.quantumcats.rawValue
        #expect(!AvatarCustomization.isOpen(value, for: .border))
        #expect(AvatarCustomization.isOpen(value, for: .border, unlocked: [.quantumCatsRing]))
        let spec = AvatarSpec.drawn(fromSeed: 7)
        #expect(throws: AvatarCustomizationError.optionLocked(slot: .border, value: value)) {
            try AvatarCustomization.applying(["border": value], to: spec, isStaff: false)
        }
        let worn = try AvatarCustomization.applying(
            ["border": value], to: spec, isStaff: false, unlocked: [.quantumCatsRing])
        #expect(worn.border == .quantumcats)
    }

    @Test func thePresentationNamesTheRingSymbol() {
        var spec = AvatarSpec.drawn(fromSeed: 11)
        spec.border = .quantumcats
        let drawn = AvatarPresentation(for: spec, size: .standard, accessibility: .decorative, isStaff: false)
        #expect(drawn.ringSymbolRef == "#av-ring-quantumcats")
        #expect(drawn.borderToken == "--avatar-border-none")
    }

    // MARK: - The art

    @Test func everyClassOfTheSymbolIsItsOwnAndStyled() throws {
        let sprite = try Self.contents(of: "Resources/Sprites/avatar-sprite.svg")
        let css = try Self.contents(of: "Public/styles.css")
        let start = try #require(sprite.range(of: #"<symbol id="av-ring-quantumcats""#))
        let end = try #require(sprite.range(of: "</symbol>", range: start.upperBound..<sprite.endIndex))
        let classes = Set(
            sprite[start.upperBound..<end.lowerBound].components(separatedBy: "class=\"").dropFirst()
                .map { String($0.prefix { $0 != "\"" }) })
        #expect(classes == [
            "av-quantumcats-band", "av-quantumcats-orbit", "av-quantumcats-orbit-line",
            "av-quantumcats-cat", "av-quantumcats-eye",
        ])
        for name in classes {
            #expect(css.contains(".\(name) {"), "\(name) has no rule")
        }
    }

    @Test func theBandIsVisibleOnEveryBackdrop() throws {
        let css = try Self.contents(of: "Public/styles.css")
        let declared = Self.values(of: "--avatar-quantumcats-band", in: css)
        // No dark mirror: a ring is the same in both themes.
        try #require(declared.count == 1, "the band is declared \(declared.count) times")
        for backdrop in AvatarBackdrop.allCases {
            let values = Self.values(of: "--avatar-back-\(backdrop.rawValue)", in: css)
            try #require(values.count == 3, "\(backdrop) has \(values.count) values")
            let light = try Self.contrast(declared[0], values[0])
            let dark = try Self.contrast(declared[0], values[1])
            #expect(light >= Self.lightFloor, "band on light \(backdrop): \(light)")
            #expect(dark >= Self.darkFloor, "band on dark \(backdrop): \(dark)")
        }
    }

    /// The staff ring's colour stays reserved.
    @Test func theBandIsNotTheStaffColour() throws {
        let css = try Self.contents(of: "Public/styles.css")
        let staff = try #require(Self.values(of: "--avatar-staff-ring", in: css).first)
        #expect(Self.values(of: "--avatar-quantumcats-band", in: css).first != staff)
    }
}
