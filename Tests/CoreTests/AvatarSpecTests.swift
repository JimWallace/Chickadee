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
        var cheeks: Set<AvatarCheek> = []
        var flanks: Set<AvatarFlank> = []
        var backdrops: Set<AvatarBackdrop> = []
        var wings: Set<AvatarWing> = []
        for seed in 0..<4_000 as Range<UInt64> {
            let spec = AvatarSpec.drawn(fromSeed: seed)
            caps.insert(spec.cap)
            cheeks.insert(spec.cheek)
            flanks.insert(spec.flank)
            backdrops.insert(spec.backdrop)
            wings.insert(spec.wing)
        }
        #expect(caps.count == AvatarCap.allCases.count)
        #expect(cheeks.count == AvatarCheek.allCases.count)
        #expect(flanks.count == AvatarFlank.allCases.count)
        #expect(backdrops.count == AvatarBackdrop.allCases.count)
        #expect(wings.count == AvatarWing.allCases.count)
    }

    @Test func combinationCountMatchesTheSlots() {
        #expect(AvatarSpec.combinationCount == 8 * 4 * 6 * 8 * 6)
        #expect(AvatarSpec.combinationCount == 9_216)
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

    @Test func aBirdIsFiveLayersInOrder() {
        let spec = AvatarSpec(cap: .plum, cheek: .snow, flank: .sand, backdrop: .sky, wing: .barred)
        #expect(
            AvatarMarkup.layerSymbolIDs(for: spec) == [
                "av-backdrop", "av-plumage", "av-wing-barred", "av-beak", "av-eyes",
            ])
    }

    @Test func presentationNamesTheSpecsTokens() {
        let spec = AvatarSpec(cap: .teal, cheek: .mint, flank: .moss, backdrop: .sage, wing: .edged)
        let p = AvatarPresentation(for: spec, size: .standard, accessibility: .decorative)
        #expect(p.capToken == "--avatar-teal-cap")
        #expect(p.wingToken == "--avatar-teal-wing")
        #expect(p.beakToken == "--avatar-teal-beak")
        #expect(p.cheekToken == "--avatar-cheek-mint")
        #expect(p.flankToken == "--avatar-flank-moss")
        #expect(p.backdropToken == "--avatar-back-sage")
        #expect(p.wingSymbolRef == "#av-wing-edged")
        #expect(p.sizeClass == "avatar")
        // No literal colour ever reaches a template.
        #expect(!p.tokens.contains { $0.contains("#") })
    }

    @Test func presentationIsDecorativeOrLabelledButNeverBoth() {
        let spec = AvatarSpec.drawn(fromSeed: 3)
        let plain = AvatarPresentation(for: spec, size: .standard, accessibility: .decorative)
        #expect(plain.isLabelled == false)
        #expect(plain.label.isEmpty)

        let named = AvatarPresentation(
            for: spec, size: .small, accessibility: .labelled("Quiet Cedar"))
        #expect(named.isLabelled)
        #expect(named.label == "Quiet Cedar")
        #expect(named.sizeClass == "avatar avatar-sm")
    }

    // MARK: - Drift against the files that own the art

    private static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)  // .../Tests/CoreTests/<thisFile>
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    private static func contents(of path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every symbol the renderer can name exists in the sprite, and every wing
    /// symbol in the sprite has a case.  Both directions, because a partial
    /// derivation is indistinguishable from a correct one — the lesson the
    /// kernel-vendoring guard learned the expensive way.
    @Test func spriteAndSlotsAgree() throws {
        let sprite = try Self.contents(of: "Resources/Views/_avatar-sprite.leaf")
        let declared = Set(Self.attributeValues(in: sprite, attribute: "id"))

        for wing in AvatarWing.allCases {
            #expect(declared.contains("av-wing-\(wing.rawValue)"), "sprite has no art for \(wing)")
        }
        let spriteWings = Set(
            declared.filter { $0.hasPrefix("av-wing-") }.map { String($0.dropFirst("av-wing-".count)) })
        #expect(
            spriteWings == Set(AvatarWing.allCases.map(\.rawValue)),
            "sprite wings \(spriteWings.sorted()) do not match AvatarWing")

        for symbol in ["av-backdrop", "av-plumage", "av-beak", "av-eyes"] {
            #expect(declared.contains(symbol), "sprite is missing \(symbol)")
        }
    }

    /// The partial draws the layers the model says it draws, in order.
    ///
    /// The five `use` elements are hard-coded in `_avatar.leaf` — a template
    /// cannot loop them, since four are literal fragments and one is an
    /// interpolation — so this is what stops the template and
    /// `layerSymbolIDs` drifting apart.
    @Test func partialStacksTheModelsLayers() throws {
        let partial = try Self.contents(of: "Resources/Views/_avatar.leaf")
        let refs = Self.attributeValues(in: partial, attribute: "href")
        let spec = AvatarSpec(cap: .ink, cheek: .snow, flank: .sand, backdrop: .sky, wing: .plain)
        let presentation = AvatarPresentation(
            for: spec, size: .standard, accessibility: .decorative)
        let expected = AvatarMarkup.layerSymbolIDs(for: spec)
            .enumerated()
            .map { index, id in index == 2 ? "#(wingSymbolRef)" : "#" + id }
        #expect(refs == expected, "partial layers \(refs) do not match the model's")
        // And the interpolated one really is the wing, marker included.
        #expect(presentation.wingSymbolRef == "#" + AvatarMarkup.layerSymbolIDs(for: spec)[2])
    }

    /// Every `--av-*` the partial assigns is one the presentation supplies, and
    /// every one the presentation supplies is assigned — in BOTH branches.
    ///
    /// The decorative and labelled branches carry byte-identical style
    /// attributes and differ only in how the bird is announced, so an edit that
    /// touches one renders a partially black bird through the other. Counting
    /// distinct names could not see that: it has to be an occurrence count, or
    /// the guard passes on exactly the drift it exists to catch.
    @Test func partialAssignsEveryPresentationPropertyInBothBranches() throws {
        let partial = try Self.contents(of: "Resources/Views/_avatar.leaf")
        let properties = [
            "--av-cap", "--av-wing", "--av-beak", "--av-cheek", "--av-wing-mark",
            "--av-flank", "--av-backdrop",
        ]
        let branches = partial.components(separatedBy: "#else:")
        #expect(branches.count == 2, "the partial no longer has two announce branches")
        for property in properties {
            let occurrences = partial.components(separatedBy: "\(property): var(").count - 1
            #expect(occurrences == 2, "\(property) is assigned \(occurrences)x, expected once per branch")
        }
        // Flat field names, not `avatar.capToken`: the sub-context form makes
        // the presentation this partial's root. Qualifying them resolves to
        // empty, silently — a bird with no colours that still returns 200.
        for field in ["capToken", "wingToken", "beakToken", "cheekToken", "flankToken", "backdropToken"] {
            #expect(partial.contains("#(\(field))"), "partial never reads \(field)")
            #expect(!partial.contains("avatar.\(field)"), "\(field) is qualified; it will resolve empty")
        }
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
        var expected: Set<String> = ["--avatar-eye", "--avatar-glint"]
        for cap in AvatarCap.allCases {
            for cheek in AvatarCheek.allCases {
                for flank in AvatarFlank.allCases {
                    for backdrop in AvatarBackdrop.allCases {
                        let spec = AvatarSpec(
                            cap: cap, cheek: cheek, flank: flank, backdrop: backdrop, wing: .plain)
                        expected.formUnion(
                            AvatarPresentation(
                                for: spec, size: .standard, accessibility: .decorative
                            ).tokens)
                    }
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
