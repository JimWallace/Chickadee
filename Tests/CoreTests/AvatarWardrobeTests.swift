// Tests/CoreTests/AvatarWardrobeTests.swift
//
// Wardrobe slice W1 (docs/student-wardrobe.md): the chosen border, the
// customization chokepoint, and the headband that replaced the gradcap in the
// first-use draw.

import Core
import Foundation
import Testing

@Suite struct AvatarWardrobeTests {

    // MARK: - The gradcap leaves the draw

    @Test func drawNeverYieldsTheGradcapAndCanYieldTheHeadband() {
        var accessories: Set<AvatarAccessory> = []
        for seed in 0..<3_000 as Range<UInt64> {
            let spec = AvatarSpec.drawn(fromSeed: seed)
            #expect(spec.accessory != .gradcap, "seed \(seed) drew the gradcap")
            accessories.insert(spec.accessory)
        }
        #expect(accessories.contains(.headband))
    }

    /// Append only: the headband is the last case, and the starter list is
    /// every accessory except the gradcap.
    @Test func headbandIsAppendedAndOnlyTheGradcapIsNotAStarter() {
        #expect(AvatarAccessory.allCases.last == .headband)
        #expect(Set(AvatarAccessory.allCases).subtracting(AvatarAccessory.starterCases) == [.gradcap])
        #expect(AvatarAccessory.starterCases.count == Set(AvatarAccessory.starterCases).count)
    }

    // MARK: - The border

    @Test func theDrawNeverChoosesABorder() {
        for seed in 0..<500 as Range<UInt64> {
            #expect(AvatarSpec.drawn(fromSeed: seed).border == .none)
        }
    }

    @Test func aSpecStoredBeforeTheBorderDecodesWithNone() throws {
        let json =
            #"{"cap":"slate","wing":"tipped","expression":"sleepy","accessory":"bloom","accent":"orchid","backdrop":"lilac","tuft":"pair","tilt":"right"}"#
        let spec = try JSONDecoder().decode(AvatarSpec.self, from: Data(json.utf8))
        #expect(spec.border == .none)
        #expect(spec.tuft == .pair)
    }

    @Test func aBorderRoundTripsThroughJSON() throws {
        var spec = AvatarSpec.drawn(fromSeed: 4)
        spec.border = .lagoon
        let data = try JSONEncoder().encode(spec)
        #expect(try JSONDecoder().decode(AvatarSpec.self, from: data) == spec)
    }

    /// Every solid-colour border names an accent, so it adds no palette token.
    @Test func everyBorderButNoneIsAnAccent() {
        for border in AvatarBorder.allCases where border.ring == .solid || border == .none {
            #expect((border.accent == nil) == (border == .none), "\(border)")
        }
    }

    /// A patterned ring colours itself by class, so it names no accent.
    @Test func patternedRingsHaveNoAccent() {
        for border in AvatarBorder.allCases where border.ring != .solid && border != .none {
            #expect(border.accent == nil, "\(border)")
        }
    }

    @Test(arguments: AvatarBorder.allCases)
    func borderTokenIsTheAccentOrTransparent(border: AvatarBorder) {
        let spec = AvatarSpec(
            cap: .ink, wing: .plain, expression: .bright, accessory: .none, accent: .ember,
            backdrop: .straw, border: border)
        let p = AvatarPresentation(for: spec, size: .standard, accessibility: .decorative, isStaff: false)
        let expected =
            border.ring == .solid ? "--avatar-accent-\(border.rawValue)" : "--avatar-border-none"
        #expect(p.borderToken == expected)
        #expect(p.tokens.contains(p.borderToken))
    }

    // MARK: - The chokepoint

    private static let base = AvatarSpec(
        cap: .teal, wing: .edged, expression: .keen, accessory: .glasses, accent: .lagoon,
        backdrop: .sage, tuft: .cowlick, tilt: .right, border: .none)

    @Test func applyingSetsOnlyTheChosenSlots() throws {
        let updated = try AvatarCustomization.applying(
            ["backdrop": "rose", "border": "honey"], to: Self.base)
        var expected = Self.base
        expected.backdrop = .rose
        expected.border = .honey
        #expect(updated == expected)

        let backdropOnly = try AvatarCustomization.applying(["backdrop": "sky"], to: Self.base)
        #expect(backdropOnly.border == Self.base.border)
        #expect(backdropOnly.backdrop == .sky)
        #expect(try AvatarCustomization.applying([:], to: Self.base) == Self.base)
    }

    @Test func applyingRefusesAnUnknownOptionOrSlot() {
        #expect(throws: AvatarCustomizationError.unknownOption(slot: .border, value: "gold")) {
            try AvatarCustomization.applying(["backdrop": "rose", "border": "gold"], to: Self.base)
        }
        #expect(throws: AvatarCustomizationError.unknownOption(slot: .backdrop, value: "Sky")) {
            try AvatarCustomization.applying(["backdrop": "Sky"], to: Self.base)
        }
        // A drawn slot is not the student's to set.
        #expect(throws: AvatarCustomizationError.slotNotCustomizable("accessory")) {
            try AvatarCustomization.applying(["accessory": "gradcap"], to: Self.base)
        }
    }

    @Test func optionsAreEveryCaseOfTheSlot() {
        #expect(AvatarCustomization.options(for: .backdrop) == AvatarBackdrop.allCases.map(\.rawValue))
        #expect(AvatarCustomization.options(for: .border) == AvatarBorder.allCases.map(\.rawValue))
    }

    // MARK: - The partial

    private static func contents(of path: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)  // .../Tests/CoreTests/<thisFile>
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }

    /// The ring is a sprite layer; a solid ring is coloured by the property the
    /// partial assigns.
    @Test func stylesheetDrawsTheRingFromTheBorderProperty() throws {
        let css = try Self.contents(of: "Public/styles.css")
        #expect(css.contains(".av-ring { fill: var(--av-border); }"))
        #expect(css.contains("--av-border: var(--avatar-border-none);"))
        // "None" paints nothing, so a bird with no border is unchanged.
        #expect(css.contains("--avatar-border-none: transparent;"))
    }
}
