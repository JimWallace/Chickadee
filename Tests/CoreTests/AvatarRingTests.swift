// Tests/CoreTests/AvatarRingTests.swift
//
// The ring layer (docs/student-wardrobe.md, "Rings" and "The staff ring"):
// every ring is sprite art, the patterned rings are tiered, and the staff ring
// is reserved — drawn from a course role and never something a student stores.

import Core
import Foundation
import Testing

@Suite struct AvatarRingTests {

    private static let base = AvatarSpec(
        cap: .umber, wing: .plain, expression: .bright, accessory: .none, accent: .moss,
        backdrop: .sage, tuft: .none, tilt: .upright, border: .lagoon)

    // MARK: - The staff ring is reserved

    /// No stored choice draws the staff ring, so no student can wear it.
    @Test func noBorderDrawsTheStaffRing() {
        for border in AvatarBorder.allCases {
            #expect(border.ring != .staff, "\(border) draws the staff ring")
        }
    }

    /// Every other ring is some border's art: nothing drawn is unreachable.
    @Test func everyRingButStaffIsSomeBordersArt() {
        let drawn = Set(AvatarBorder.allCases.map(\.ring))
        #expect(drawn == Set(AvatarRing.allCases).subtracting([.staff]))
    }

    @Test func staffWearTheStaffRingWhateverTheyChose() {
        for border in AvatarBorder.allCases {
            var spec = Self.base
            spec.border = border
            let p = AvatarPresentation(
                for: spec, size: .roster, accessibility: .decorative, isStaff: true)
            #expect(p.ringSymbolRef == "#av-ring-staff")
            #expect(p.borderToken == "--avatar-border-none")
            #expect(p.layerRefs.last == "#av-ring-staff")
        }
    }

    @Test func aStudentWearsTheRingTheyChose() {
        for border in AvatarBorder.allCases {
            var spec = Self.base
            spec.border = border
            let p = AvatarPresentation(for: spec, size: .standard, accessibility: .decorative)
            #expect(p.ringSymbolRef == "#av-ring-\(border.ring.rawValue)")
            #expect(
                p
                    == AvatarPresentation(
                        for: spec, size: .standard, accessibility: .decorative, isStaff: false))
        }
    }

    // MARK: - Tiers

    @Test func ringTiers() {
        #expect(AvatarBorder.rainbow.availability == .starter)
        #expect(AvatarBorder.twotone.availability == .earned)
        #expect(AvatarBorder.stitched.availability == .earned)
        #expect(AvatarBorder.spectrum.availability == .special)
        for border in [AvatarBorder.none, .ember, .orchid, .lagoon, .honey, .moss] {
            #expect(border.availability == .starter, "\(border)")
        }
    }

    @Test func ringNamesReadAsWords() {
        #expect(AvatarBorder.twotone.displayName == "Two-tone")
        #expect(AvatarBorder.rainbow.displayName == "Rainbow")
        #expect(AvatarBorder.none.displayName == "None")
    }

    /// Append only: the patterned rings follow the colour rings, in this order.
    @Test func patternedRingsAreAppended() {
        #expect(
            Array(AvatarBorder.allCases.dropFirst(6)) == [.rainbow, .spectrum, .twotone, .stitched])
    }

    // MARK: - The chokepoint

    @Test func aStarterRingCanBeChosen() throws {
        let updated = try AvatarCustomization.applying(["border": "rainbow"], to: Self.base)
        #expect(updated.border == .rainbow)
        #expect(AvatarCustomization.isOpen("rainbow", for: .border))
    }

    @Test(arguments: ["spectrum", "twotone", "stitched"])
    func aLockedRingIsRefusedAndChangesNothing(value: String) {
        #expect(!AvatarCustomization.isOpen(value, for: .border))
        #expect(throws: AvatarCustomizationError.optionLocked(slot: .border, value: value)) {
            try AvatarCustomization.applying(["backdrop": "rose", "border": value], to: Self.base)
        }
    }

    @Test func staffCannotChooseARingButCanChooseABackdrop() throws {
        #expect(throws: AvatarCustomizationError.staffRingIsFixed) {
            try AvatarCustomization.applying(["border": "ember"], to: Self.base, isStaff: true)
        }
        let updated = try AvatarCustomization.applying(
            ["backdrop": "rose"], to: Self.base, isStaff: true)
        #expect(updated.backdrop == .rose)
        #expect(updated.border == Self.base.border)
    }

    // MARK: - Drift against the files that own the art

    private static func contents(of path: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)  // .../Tests/CoreTests/<thisFile>
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }

    /// Both directions: every ring has art, and every ring symbol has a case.
    @Test func spriteRingsMatchTheEnum() throws {
        let sprite = try Self.contents(of: "Resources/Views/_avatar-sprite.leaf")
        var found: Set<String> = []
        var rest = Substring(sprite)
        while let start = rest.range(of: "id=\"av-ring-") {
            let tail = rest[start.upperBound...]
            if let end = tail.firstIndex(of: "\"") { found.insert(String(tail[..<end])) }
            rest = tail
        }
        #expect(found == Set(AvatarRing.allCases.map(\.rawValue)))
    }

    /// The ring is the last layer, outside the tilt group, and carries the hook
    /// the live preview swaps.
    @Test func partialDrawsTheRingLastAndUntilted() throws {
        let partial = try Self.contents(of: "Resources/Views/_avatar.leaf")
        let body = try #require(partial.components(separatedBy: "#endif").last)
        let close = try #require(body.range(of: "</g>"))
        let ring = try #require(body.range(of: "<use href=\"#(ringSymbolRef)\" data-av-ring/>"))
        let end = try #require(body.range(of: "</svg>"))
        #expect(ring.lowerBound > close.upperBound && ring.upperBound <= end.lowerBound)
    }

    /// The staff colour is none of the student ring colours, and it has a
    /// dark-mode mirror in both dark blocks so it reads on a dark backdrop.
    @Test func staffRingColourIsReservedAndMirrored() throws {
        let css = try Self.contents(of: "Public/styles.css")
        func value(of token: String) -> String? {
            guard let start = css.range(of: "\(token):") else { return nil }
            let tail = css[start.upperBound...]
            return tail.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
        }
        let staff = try #require(value(of: "--avatar-staff-ring"))
        let studentTokens =
            AvatarAccent.allCases.map { "--avatar-accent-\($0.rawValue)" }
            + ["red", "orange", "yellow", "green", "blue", "violet"].map { "--avatar-rainbow-\($0)" }
        for token in studentTokens {
            #expect(value(of: token) != staff, "\(token) is the staff colour")
        }
        // Light, the dark media block and the explicit dark-theme block.
        #expect(css.components(separatedBy: "--avatar-staff-ring:").count - 1 == 3)
    }
}
