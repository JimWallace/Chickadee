// Tests/CoreTests/AvatarTuneUpTests.swift
//
// The avatar tune-up: the tuft and tilt axes, the three unlockable
// expressions that the first-use draw must never yield, stored specs that
// predate both, and the sprite rules the new art has to keep
// (docs/student-avatars.md, decision 7 "Tune-up").

import Core
import Foundation
import Testing

@Suite struct AvatarTuneUpTests {

    // MARK: - Starter draw

    private static let unlockables: Set<AvatarExpression> = [.chirp, .sly, .dreamy]

    @Test func drawNeverYieldsAnUnlockableExpression() {
        for seed in 0..<5_000 as Range<UInt64> {
            let spec = AvatarSpec.drawn(fromSeed: seed)
            #expect(!Self.unlockables.contains(spec.expression), "seed \(seed) drew \(spec.expression)")
        }
    }

    /// Append only: the starter list is the first six cases, and the three
    /// unlockables come after them, in this order.
    @Test func starterCasesAreTheFirstSixAndUnlockablesAreAppended() {
        #expect(AvatarExpression.starterCases == Array(AvatarExpression.allCases.prefix(6)))
        #expect(Array(AvatarExpression.allCases.dropFirst(6)) == [.chirp, .sly, .dreamy])
    }

    @Test func everyTuftAndTiltIsDrawable() {
        var tufts: Set<AvatarTuft> = []
        var tilts: Set<AvatarTilt> = []
        for seed in 0..<2_000 as Range<UInt64> {
            let spec = AvatarSpec.drawn(fromSeed: seed)
            tufts.insert(spec.tuft)
            tilts.insert(spec.tilt)
        }
        #expect(tufts == Set(AvatarTuft.allCases))
        #expect(tilts == Set(AvatarTilt.allCases))
    }

    @Test func starterCombinationCountUsesOnlyStarterExpressions() {
        #expect(AvatarSpec.starterCombinationCount == 8 * 6 * 6 * 8 * 5 * 8 * 5 * 3)
        #expect(AvatarSpec.starterCombinationCount == 1_382_400)
    }

    // MARK: - Stored specs that predate the axes

    private static let preTuneUpJSON =
        #"{"cap":"slate","wing":"tipped","expression":"sleepy","accessory":"bloom","accent":"orchid","backdrop":"lilac"}"#

    @Test func preTuneUpJSONStillDecodes() throws {
        let spec = try JSONDecoder().decode(AvatarSpec.self, from: Data(Self.preTuneUpJSON.utf8))
        #expect(
            spec
                == AvatarSpec(
                    cap: .slate, wing: .tipped, expression: .sleepy, accessory: .bloom,
                    accent: .orchid, backdrop: .lilac, tuft: .none, tilt: .upright))
    }

    @Test func missingAxesTellsAnAbsentKeyFromADefaultValue() throws {
        #expect(AvatarSpec.missingAxes(inStoredJSON: Self.preTuneUpJSON) == [.tuft, .tilt])

        let current = AvatarSpec.drawn(fromSeed: 11)
        let data = try JSONEncoder().encode(current)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(AvatarSpec.missingAxes(inStoredJSON: json).isEmpty)

        let tuftOnly = Self.preTuneUpJSON.dropLast() + #","tuft":"none"}"#
        #expect(AvatarSpec.missingAxes(inStoredJSON: String(tuftOnly)) == [.tilt])
        #expect(AvatarSpec.missingAxes(inStoredJSON: "not json").isEmpty)
    }

    @Test func fillingMissingChangesOnlyTheNamedAxes() {
        let original = AvatarSpec(
            cap: .rust, wing: .speckled, expression: .curious, accessory: .glasses, accent: .moss,
            backdrop: .peach, tuft: .swoop, tilt: .left)
        for seed in 0..<200 as Range<UInt64> {
            var generator = AvatarSeedGenerator(seed: seed)
            let tiltOnly = original.fillingMissing([.tilt], using: &generator)
            var expected = original
            expected.tilt = tiltOnly.tilt
            #expect(tiltOnly == expected)

            let none = original.fillingMissing([], using: &generator)
            #expect(none == original)

            let both = original.fillingMissing([.tuft, .tilt], using: &generator)
            expected = original
            expected.tuft = both.tuft
            expected.tilt = both.tilt
            #expect(both == expected)
        }
    }

    // MARK: - Presentation

    @Test func presentationNamesTheTuftAndTilt() {
        let spec = AvatarSpec(
            cap: .forest, wing: .plain, expression: .dreamy, accessory: .none, accent: .ember,
            backdrop: .sky, tuft: .crest, tilt: .left)
        let p = AvatarPresentation(for: spec, size: .roster, accessibility: .decorative)
        #expect(p.tuftSymbolRef == "#av-tuft-crest")
        #expect(p.expressionSymbolRef == "#av-expression-dreamy")
        #expect(p.tiltTransform == "rotate(-9 32 34)")
    }

    /// The tuft reference and the tilt transform are never empty, including
    /// for the two "nothing" values — Leaf gives an empty value no warning.
    @Test(arguments: AvatarTuft.allCases)
    func tuftRefAndTiltTransformAreNeverEmpty(tuft: AvatarTuft) {
        for tilt in AvatarTilt.allCases {
            let spec = AvatarSpec(
                cap: .ink, wing: .plain, expression: .bright, accessory: .none, accent: .ember,
                backdrop: .sky, tuft: tuft, tilt: tilt)
            let p = AvatarPresentation(for: spec, size: .standard, accessibility: .decorative)
            #expect(p.tuftSymbolRef == "#av-tuft-\(tuft.rawValue)")
            #expect(p.tiltTransform == "rotate(\(tilt.degrees) 32 34)")
        }
        #expect(AvatarTilt.upright.degrees == 0)
        #expect(AvatarTilt.left.degrees == -9)
        #expect(AvatarTilt.right.degrees == 9)
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

    /// The sprite's symbols without its header comment, which names the
    /// forbidden constructs in prose.
    private static func spriteMarkup() throws -> String {
        let sprite = try contents(of: "Resources/Views/_avatar-sprite.leaf")
        guard let end = sprite.range(of: "-->") else { return sprite }
        return String(sprite[end.upperBound...])
    }

    private static func symbolIDs(in markup: String, family: String) -> Set<String> {
        var found: Set<String> = []
        var rest = Substring(markup)
        let needle = "id=\"av-\(family)-"
        while let start = rest.range(of: needle) {
            let tail = rest[start.upperBound...]
            if let end = tail.firstIndex(of: "\"") { found.insert(String(tail[..<end])) }
            rest = tail
        }
        return found
    }

    /// Both directions: every tuft case has art, and every tuft symbol has a
    /// case.
    @Test func spriteTuftsMatchTheEnum() throws {
        let markup = try Self.spriteMarkup()
        #expect(Self.symbolIDs(in: markup, family: "tuft") == Set(AvatarTuft.allCases.map(\.rawValue)))
    }

    /// Both directions for the expressions, the three unlockables included.
    @Test func spriteExpressionsMatchTheEnum() throws {
        let markup = try Self.spriteMarkup()
        let symbols = Self.symbolIDs(in: markup, family: "expression")
        #expect(symbols == Set(AvatarExpression.allCases.map(\.rawValue)))
        for unlockable in Self.unlockables {
            #expect(symbols.contains(unlockable.rawValue), "no art for \(unlockable)")
        }
    }

    /// Rule 1 of the sprite: a clipPath, mask, filter or gradient referenced
    /// from a symbol in a hidden sprite silently does not apply in Chromium.
    @Test func spriteUsesNoClipMaskFilterOrGradient() throws {
        let markup = try Self.spriteMarkup().lowercased()
        for forbidden in ["clip-path", "clippath", "mask", "filter", "gradient", "url("] {
            #expect(!markup.contains(forbidden), "sprite contains \(forbidden)")
        }
    }

    /// Rule 2: colour comes from a class. Every class the sprite uses has a
    /// rule in the stylesheet, the three new ones among them.
    @Test func everySpriteClassHasAStylesheetRule() throws {
        let markup = try Self.spriteMarkup()
        let css = try Self.contents(of: "Public/styles.css")
        var classes: Set<String> = []
        var rest = Substring(markup)
        while let start = rest.range(of: "class=\"") {
            let tail = rest[start.upperBound...]
            if let end = tail.firstIndex(of: "\"") {
                classes.formUnion(tail[..<end].split(separator: " ").map(String.init))
            }
            rest = tail
        }
        for required in ["av-brow", "av-blush", "av-mouth"] {
            #expect(classes.contains(required), "sprite never uses \(required)")
        }
        for cls in classes.subtracting(["icon-sprite"]) {
            #expect(css.contains(".\(cls) {"), "styles.css has no rule for .\(cls)")
        }
        #expect(!markup.contains(" fill=\"#"), "a literal fill colour in the sprite")
    }

    /// The tilt group wraps every layer but the backdrop, and sits after the
    /// announce branches close — so it applies to BOTH of them.
    @Test func partialTiltsEveryLayerButTheBackdropInBothBranches() throws {
        let partial = try Self.contents(of: "Resources/Views/_avatar.leaf")
        let body = try #require(partial.components(separatedBy: "#endif").last)
        #expect(partial.components(separatedBy: "#(tiltTransform)").count - 1 == 1)
        let backdrop = try #require(body.range(of: "<use href=\"#av-backdrop\"/>"))
        let group = try #require(body.range(of: "<g transform=\"#(tiltTransform)\">"))
        let close = try #require(body.range(of: "</g>"))
        #expect(backdrop.upperBound <= group.lowerBound, "the backdrop must not tilt")
        for layer in [
            "#(tuftSymbolRef)", "#av-plumage", "#(wingSymbolRef)", "#(expressionSymbolRef)",
            "#(accessorySymbolRef)",
        ] {
            let use = try #require(body.range(of: "<use href=\"\(layer)\"/>"), "no \(layer) layer")
            #expect(use.lowerBound > group.upperBound && use.upperBound < close.lowerBound)
        }
    }
}
