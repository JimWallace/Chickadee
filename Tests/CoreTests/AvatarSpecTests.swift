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

    // MARK: - Markup

    @Test func aBirdIsFiveLayersInOrder() {
        let spec = AvatarSpec(cap: .plum, cheek: .snow, flank: .sand, backdrop: .sky, wing: .barred)
        #expect(
            AvatarMarkup.layerSymbolIDs(for: spec) == [
                "av-backdrop", "av-plumage", "av-wing-barred", "av-beak", "av-eyes",
            ])
    }

    @Test func customPropertiesNameTheSpecsTokens() {
        let spec = AvatarSpec(cap: .teal, cheek: .mint, flank: .moss, backdrop: .sage, wing: .edged)
        let css = AvatarMarkup.customProperties(for: spec)
        #expect(css.contains("--av-cap: var(--avatar-teal-cap)"))
        #expect(css.contains("--av-wing: var(--avatar-teal-wing)"))
        #expect(css.contains("--av-beak: var(--avatar-teal-beak)"))
        #expect(css.contains("--av-cheek: var(--avatar-cheek-mint)"))
        #expect(css.contains("--av-flank: var(--avatar-flank-moss)"))
        #expect(css.contains("--av-backdrop: var(--avatar-back-sage)"))
        // Wing marks take the cheek colour, so a patterned wing reads against
        // any cap family without a slot of its own.
        #expect(css.contains("--av-wing-mark: var(--avatar-cheek-mint)"))
        // No literal colour ever reaches the markup.
        #expect(!css.contains("#"))
    }

    @Test func inlineSVGIsDecorativeByDefaultAndLabelledOnRequest() {
        let spec = AvatarSpec.drawn(fromSeed: 3)
        let plain = AvatarMarkup.inlineSVG(for: spec)
        #expect(plain.contains(#"class="avatar""#))
        #expect(plain.contains(#"aria-hidden="true""#))
        #expect(!plain.contains("aria-label"))

        let labelled = AvatarMarkup.inlineSVG(
            for: spec, size: .small, accessibility: .labelled("Quiet Cedar"))
        #expect(labelled.contains(#"class="avatar avatar-sm""#))
        #expect(labelled.contains(#"role="img""#))
        #expect(labelled.contains(#"aria-label="Quiet Cedar""#))
    }

    @Test func aLabelIsEscaped() {
        let markup = AvatarMarkup.inlineSVG(
            for: AvatarSpec.drawn(fromSeed: 1), accessibility: .labelled(#"a"<b>&"#))
        #expect(markup.contains("&quot;&lt;b&gt;&amp;"))
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

    /// The palette the renderer names and the palette the stylesheet declares
    /// are the same set.  A token named but not declared renders black; a token
    /// declared but not named is dead paint nobody can pick.
    @Test func paletteAndSlotsAgree() throws {
        let css = try Self.contents(of: "Public/styles.css")
        let declared = Self.declaredAvatarTokens(in: css)

        var expected: Set<String> = ["--avatar-eye", "--avatar-glint"]
        for cap in AvatarCap.allCases {
            expected.formUnion([
                "--avatar-\(cap.rawValue)-cap",
                "--avatar-\(cap.rawValue)-wing",
                "--avatar-\(cap.rawValue)-beak",
            ])
        }
        expected.formUnion(AvatarCheek.allCases.map { "--avatar-cheek-\($0.rawValue)" })
        expected.formUnion(AvatarFlank.allCases.map { "--avatar-flank-\($0.rawValue)" })
        expected.formUnion(AvatarBackdrop.allCases.map { "--avatar-back-\($0.rawValue)" })

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
