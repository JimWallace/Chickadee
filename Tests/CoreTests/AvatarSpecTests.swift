import ChickadeeTestSupport
import Core
import Foundation
import Testing

@Suite struct AvatarSpecTests {

    // MARK: - Drawing

    @Test func drawIsReproducibleFromASeed() {
        for seed in [0, 1, 42, 9_999, UInt64.max] as [UInt64] {
            #expect(AvatarSpec.drawn(fromSeed: seed) == AvatarSpec.drawn(fromSeed: seed))
        }
    }

    @Test func differentSeedsProduceDifferentBirds() {
        let drawn = Set((0..<512 as Range<UInt64>).map { AvatarSpec.drawn(fromSeed: $0) })
        // 512 draws from 9,216 combinations: a generator stuck on one slot, or
        // one seeded so weakly that neighbouring seeds collide, lands far under
        // this.  A healthy draw sits near 500.
        #expect(drawn.count > 450, "only \(drawn.count) distinct birds in 512 draws")
    }

    /// Every option of every slot has to be reachable.  A slot that silently
    /// never yields its last case is invisible in any single rendering — you
    /// simply never see that bird — so it is asserted rather than eyeballed.
    @Test func everyOptionOfEverySlotIsDrawable() {
        var caps: Set<AvatarCap> = []
        var wings: Set<AvatarWing> = []
        var expressions: Set<AvatarExpression> = []
        var accessories: Set<AvatarAccessory> = []
        var accents: Set<AvatarAccent> = []
        var backdrops: Set<AvatarBackdrop> = []
        for seed in 0..<4_000 as Range<UInt64> {
            let spec = AvatarSpec.drawn(fromSeed: seed)
            caps.insert(spec.cap)
            wings.insert(spec.wing)
            expressions.insert(spec.expression)
            accessories.insert(spec.accessory)
            accents.insert(spec.accent)
            backdrops.insert(spec.backdrop)
        }
        #expect(caps.count == AvatarCap.allCases.count)
        #expect(wings.count == AvatarWing.allCases.count)
        // Starter expressions only: the unlockables are never drawn.
        #expect(expressions == Set(AvatarExpression.starterCases))
        // Starter accessories only: the gradcap is kept for an achievement.
        #expect(accessories == Set(AvatarAccessory.starterCases))
        #expect(accents.count == AvatarAccent.allCases.count)
        #expect(backdrops.count == AvatarBackdrop.allCases.count)
    }

    @Test func combinationCountMatchesTheSlots() {
        // 38 colourways (the chickadee's 8 and 3 for each of the ten other
        // species), 6 wings, 9 expressions (6 starter + 3 unlockable),
        // 9 accessories (8 starter + the gradcap) in 5 accents, 8 backdrops,
        // 5 tufts, 3 tilts. The accent multiplies — it is part of the
        // accessory axis. The border is chosen, not drawn, so it is not counted.
        #expect(AvatarSpec.combinationCount == 38 * 6 * 9 * 9 * 5 * 8 * 5 * 3)
        #expect(AvatarSpec.combinationCount == 11_080_800)
    }

    @Test func specRoundTripsThroughJSON() throws {
        let spec = AvatarSpec.drawn(fromSeed: 7)
        let data = try JSONEncoder().encode(spec)
        #expect(try JSONDecoder().decode(AvatarSpec.self, from: data) == spec)
        let json = try #require(String(data: data, encoding: .utf8))
        // String raw values, so a stored spec is legible in the column.
        #expect(json.contains(spec.cap.rawValue))
    }

    // MARK: - Presentation

    @Test func aBirdIsSevenLayersInOrder() {
        let spec = AvatarSpec(
            cap: .plum, wing: .barred, expression: .wink, accessory: .scarf, accent: .ember,
            backdrop: .sky)
        let layers = AvatarPresentation(
            for: spec, size: .standard, accessibility: .decorative, isStaff: false
        ).layerRefs
        #expect(
            layers == [
                "#av-backdrop", "#av-tuft-none", "#av-plumage-chickadee", "#av-wing-barred",
                "#av-expression-wink", "#av-accessory-scarf", "#av-ring-none",
            ])
    }

    @Test func presentationNamesTheSpecsTokens() {
        let spec = AvatarSpec(
            cap: .teal, wing: .edged, expression: .keen, accessory: .glasses, accent: .lagoon,
            backdrop: .sage)
        let p = AvatarPresentation(for: spec, size: .standard, accessibility: .decorative, isStaff: false)
        #expect(p.capToken == "--avatar-teal-cap")
        #expect(p.wingToken == "--avatar-teal-wing")
        #expect(p.backdropToken == "--avatar-back-sage")
        #expect(p.accentToken == "--avatar-accent-lagoon")
        #expect(p.wingSymbolRef == "#av-wing-edged")
        #expect(p.expressionSymbolRef == "#av-expression-keen")
        #expect(p.accessorySymbolRef == "#av-accessory-glasses")
        #expect(p.sizeClass == "avatar")
        // No literal colour ever reaches a template.
        #expect(!p.tokens.contains { $0.contains("#") })
    }

    @Test func presentationIsDecorativeOrLabelledButNeverBoth() {
        let spec = AvatarSpec.drawn(fromSeed: 3)
        let plain = AvatarPresentation(for: spec, size: .standard, accessibility: .decorative, isStaff: false)
        #expect(plain.label == nil)

        let named = AvatarPresentation(
            for: spec, size: .standard, accessibility: .labelled("Quiet Cedar"), isStaff: false)
        #expect(named.label == "Quiet Cedar")
    }

    // MARK: - Drift against the files that own the art

    private static func contents(of path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every symbol the renderer can name exists in the sprite, and every wing
    /// symbol in the sprite has a case.  Both directions, because a partial
    /// derivation is indistinguishable from a correct one — the lesson the
    /// kernel-vendoring guard learned the expensive way.
    @Test func spriteAndSlotsAgree() throws {
        // The sprite is static SVG the server inlines raw, kept beside the
        // icon sprite in Resources/Sprites.
        let sprite = try Self.contents(of: "Resources/Sprites/avatar-sprite.svg")
        let declared = Set(Self.attributeValues(in: sprite, attribute: "id"))

        for wing in AvatarWing.allCases {
            #expect(declared.contains("av-wing-\(wing.rawValue)"), "sprite has no art for \(wing)")
        }
        for family in ["expression", "accessory"] {
            let cases: [String] =
                family == "expression"
                ? AvatarExpression.allCases.map(\.rawValue)
                : AvatarAccessory.allCases.map(\.rawValue)
            let inSprite = Set(
                declared.filter { $0.hasPrefix("av-\(family)-") }
                    .map { String($0.dropFirst("av-\(family)-".count)) })
            #expect(
                inSprite == Set(cases),
                "sprite \(family)s \(inSprite.sorted()) do not match the enum")
        }
        // The shared wing symbols only: a species' own art is
        // av-wing-<species>-<pattern>, pinned by AvatarSpeciesTests.
        let spriteWings = Set(
            declared.filter { $0.hasPrefix("av-wing-") }
                .map { String($0.dropFirst("av-wing-".count)) }
                .filter { !$0.contains("-") })
        #expect(
            spriteWings == Set(AvatarWing.allCases.map(\.rawValue)),
            "sprite wings \(spriteWings.sorted()) do not match AvatarWing")
        for symbol in ["av-backdrop", "av-plumage-chickadee"] {
            #expect(declared.contains(symbol), "sprite is missing \(symbol)")
        }
    }

    /// The `Avatar` view draws the layers the model says it draws, in order.
    ///
    /// The `use` elements are written one by one in `Avatar.swift` — the two
    /// fixed layers are literal fragments and the varying ones are
    /// presentation fields — so this is what stops the view and `layerRefs`
    /// drifting apart. Read from the view's source, in its Swift spelling.
    @Test func avatarViewStacksTheModelsLayers() throws {
        let view = try Self.contents(of: "Sources/APIServer/Views/Avatar.swift")
        let refs = view.matches(of: /\.href\(([^)]*)\)/).map { String($0.1) }
        let spec = AvatarSpec(
            cap: .ink, wing: .plain, expression: .bright, accessory: .none, accent: .ember,
            backdrop: .sky)
        let presentation = AvatarPresentation(
            for: spec, size: .standard, accessibility: .decorative, isStaff: false)
        // The varying layers are presentation fields; the one fixed layer is
        // a literal fragment.
        let expected = [
            "\"#av-backdrop\"", "avatar.tuftSymbolRef", "avatar.plumageSymbolRef", "avatar.wingSymbolRef",
            "avatar.expressionSymbolRef", "avatar.accessorySymbolRef", "avatar.ringSymbolRef",
        ]
        #expect(refs == expected, "Avatar layers \(refs) do not match the model's")
        // And the interpolated one really is the wing, marker included.
        #expect(presentation.layerRefs.count == 7)
        #expect(presentation.layerRefs[3] == "#av-wing-plain")
        #expect(presentation.wingSymbolRef == "#av-wing-plain")
    }

    /// Every `--av-*` the `Avatar` view assigns is one the presentation
    /// supplies, and every one the presentation supplies is assigned — in BOTH
    /// branches.
    ///
    /// The list is `AvatarPresentation.inlineProperties`, not a copy of it: a
    /// sixth per-student token added there is asserted here the same day, and
    /// a property the view assigns that the list does not name fails the
    /// count (#1761).
    ///
    /// The decorative and labelled branches must carry identical style
    /// attributes and differ only in how the bird is announced, so an edit that
    /// touches one renders a partially black bird through the other. The view
    /// writes the assignments once, in `customProperties`, and each branch
    /// must use that one string: so each assignment occurs once, and the style
    /// attribute reads `customProperties` exactly once per branch. Counting
    /// occurrences rather than distinct names is what catches a second,
    /// drifting copy.
    @Test func avatarViewAssignsEveryPresentationPropertyInBothBranches() throws {
        let view = try Self.contents(of: "Sources/APIServer/Views/Avatar.swift")
        let spec = AvatarSpec(
            cap: .plum, wing: .barred, expression: .wink, accessory: .scarf, accent: .ember,
            backdrop: .sky)
        let properties =
            AvatarPresentation(for: spec, size: .standard, accessibility: .decorative, isStaff: false)
            .inlineProperties
        let branches = view.components(separatedBy: "} else {")
        #expect(branches.count == 2, "the view no longer has two announce branches")
        let styleUse = #".custom(name: "style", value: customProperties)"#
        for branch in branches {
            #expect(
                branch.components(separatedBy: styleUse).count - 1 == 1,
                "an announce branch does not take its style from customProperties exactly once")
        }
        for property in properties {
            let assignment = "\(property.name): var(\\(avatar.\(property.field)))"
            let occurrences = view.components(separatedBy: assignment).count - 1
            #expect(occurrences == 1, "\(property.name) is assigned \(occurrences)x, expected once for both branches")
        }
        let assigned = view.components(separatedBy: "--av-").count - 1
        #expect(
            assigned == properties.count,
            "the view assigns \(assigned) --av- properties; the list names \(properties.count)")
    }

    /// The palette the renderer names and the palette the stylesheet declares
    /// are the same set.  A token named but not declared renders black; a token
    /// declared but not named is dead paint nobody can pick.
    @Test func paletteAndSlotsAgree() throws {
        let css = try Self.contents(of: "Public/styles.css")
        let declared = Self.declaredAvatarTokens(in: css)

        // Built from what a presentation can actually NAME, over every spec the
        // slots can produce — not from a hand-written list, which would be a
        // third spelling of the palette and the thing most likely to drift.
        var expected: Set<String> = [
            "--avatar-bloom-eye", "--avatar-eyewhite",
            "--avatar-eye", "--avatar-glint", "--avatar-gear", "--avatar-blush",
            "--avatar-mouth", "--avatar-rainbow-red", "--avatar-rainbow-orange",
            "--avatar-rainbow-yellow", "--avatar-rainbow-green", "--avatar-rainbow-blue",
            "--avatar-rainbow-violet", "--avatar-staff-ring",
        ]
        for cap in AvatarCap.allCases {
            for accent in AvatarAccent.allCases {
                for backdrop in AvatarBackdrop.allCases {
                    let spec = AvatarSpec(
                        cap: cap, wing: .plain, expression: .bright, accessory: .none,
                        accent: accent, backdrop: backdrop)
                    expected.formUnion(
                        AvatarPresentation(for: spec, size: .standard, accessibility: .decorative, isStaff: false)
                            .tokens)
                }
            }
        }

        let unmet = expected.subtracting(declared).sorted()
        let unreachable = declared.subtracting(expected).sorted()
        #expect(
            declared == expected,
            "named but not declared: \(unmet); declared but unnameable: \(unreachable)")
    }

    /// Custom-property *declarations* only: `--avatar-x: value`.  A `var()`
    /// reference is followed by `)`, never `:`, so this scan skips the ones the
    /// `.avatar` defaults make.
    private static func declaredAvatarTokens(in css: String) -> Set<String> {
        var found: Set<String> = []
        var rest = Substring(css)
        while let start = rest.range(of: "--avatar-") {
            let tail = rest[start.lowerBound...]
            let name = tail.prefix { $0.isLowercase || $0 == "-" }
            if tail.dropFirst(name.count).first == ":" { found.insert(String(name)) }
            rest = rest[start.upperBound...]
        }
        return found
    }

    private static func attributeValues(in markup: String, attribute: String) -> [String] {
        var values: [String] = []
        var rest = Substring(markup)
        let needle = "\(attribute)=\""
        while let start = rest.range(of: needle) {
            let tail = rest[start.upperBound...]
            if let end = tail.firstIndex(of: "\"") { values.append(String(tail[..<end])) }
            rest = rest[start.upperBound...]
        }
        return values
    }
}
