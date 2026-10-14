import ChickadeeTestSupport
import Core
import Foundation
import Testing

/// The species layer over the avatar model (docs/avatar-species.md): a
/// species is derived from the colourway, each species owns its plumage art
/// and its colourways, and everything else is shared.
@Suite struct AvatarSpeciesTests {

    // MARK: - The partition

    /// Every colourway belongs to exactly one species. This is what lets the
    /// species be derived instead of stored: a spec saved before any species
    /// but the chickadee existed names a chickadee colourway and IS one.
    @Test func colourwaysPartitionTheCapEnum() {
        var owners: [AvatarCap: [AvatarSpecies]] = [:]
        for species in AvatarSpecies.allCases {
            for cap in species.colourways { owners[cap, default: []].append(species) }
        }
        for cap in AvatarCap.allCases {
            #expect(owners[cap]?.count == 1, "\(cap) belongs to \(owners[cap] ?? [])")
            #expect(AvatarSpecies.of(cap) == owners[cap]?.first)
        }
        #expect(owners.count == AvatarCap.allCases.count)
    }

    @Test func everySpeciesHasAtLeastThreeColourways() {
        for species in AvatarSpecies.allCases {
            #expect(species.colourways.count >= 3, "\(species) has \(species.colourways.count)")
        }
    }

    /// The eight colourways that existed before the species did are the
    /// chickadee's, so no stored bird changes species.
    @Test func theOriginalEightColourwaysAreChickadees() {
        for cap in [AvatarCap.slate, .plum, .forest, .indigo, .rust, .teal, .umber, .ink] {
            #expect(AvatarSpecies.of(cap) == .chickadee)
        }
    }

    @Test func aStoredSpecWithNoSpeciesKeyIsAChickadee() throws {
        let json =
            #"{"cap":"plum","wing":"barred","expression":"wink","accessory":"scarf","accent":"ember","backdrop":"sky"}"#
        let spec = try JSONDecoder().decode(AvatarSpec.self, from: Data(json.utf8))
        #expect(spec.species == .chickadee)
        // And the species is never written: the colourway carries it.
        let encoded = try #require(String(data: JSONEncoder().encode(spec), encoding: .utf8))
        #expect(!encoded.contains("species"))
    }

    // MARK: - The draw

    /// Each species is equally likely, then a colourway of that species. A
    /// draw over every colourway at once would make a chickadee eight times
    /// as likely as a cardinal.
    @Test func drawPicksEverySpeciesAboutEqually() {
        var counts: [AvatarSpecies: Int] = [:]
        let draws = 5_000
        for seed in 0..<UInt64(draws) {
            counts[AvatarSpec.drawn(fromSeed: seed).species, default: 0] += 1
        }
        let expected = draws / AvatarSpecies.allCases.count
        for species in AvatarSpecies.allCases {
            let count = counts[species] ?? 0
            #expect(abs(count - expected) < expected / 4, "\(species) drawn \(count) times of \(draws)")
        }
    }

    @Test func drawnColourwayAlwaysBelongsToItsSpecies() {
        for seed in 0..<2_000 as Range<UInt64> {
            let spec = AvatarSpec.drawn(fromSeed: seed)
            #expect(spec.species.colourways.contains(spec.cap))
        }
    }

    @Test func everyColourwayIsDrawable() {
        var caps: Set<AvatarCap> = []
        for seed in 0..<4_000 as Range<UInt64> { caps.insert(AvatarSpec.drawn(fromSeed: seed).cap) }
        #expect(caps == Set(AvatarCap.allCases))
    }

    // MARK: - Presentation

    @Test func presentationNamesTheSpeciesPlumageAndTheColourwaysSixTokens() {
        let spec = AvatarSpec(
            cap: .copper, wing: .edged, expression: .keen, accessory: .glasses, accent: .lagoon,
            backdrop: .sage)
        let p = AvatarPresentation(for: spec, size: .standard, accessibility: .decorative, isStaff: false)
        #expect(p.plumageSymbolRef == "#av-plumage-robin")
        #expect(p.layerRefs[2] == "#av-plumage-robin")
        #expect(p.capToken == "--avatar-copper-cap")
        #expect(p.wingToken == "--avatar-copper-wing")
        #expect(p.bodyToken == "--avatar-copper-body")
        #expect(p.bibToken == "--avatar-copper-bib")
        #expect(p.beakToken == "--avatar-copper-beak")
        #expect(p.markToken == "--avatar-copper-mark")
        #expect(p.inlineProperties.count == 9)
    }

    /// A crested species with no tuft wears its crest; with a tuft it wears
    /// the tuft; under a hat it wears neither. An uncrested species with no
    /// tuft wears none.
    @Test func crestIsTheBareHeadOfACrestedSpeciesAndHidesUnderAHat() {
        func tuftRef(_ cap: AvatarCap, tuft: AvatarTuft, accessory: AvatarAccessory) -> String {
            let spec = AvatarSpec(
                cap: cap, wing: .plain, expression: .bright, accessory: accessory, accent: .ember,
                backdrop: .sky, tuft: tuft)
            return AvatarPresentation(for: spec, size: .standard, accessibility: .decorative, isStaff: false)
                .tuftSymbolRef
        }
        #expect(tuftRef(.scarlet, tuft: .none, accessory: .none) == "#av-crest-cardinal")
        #expect(tuftRef(.azure, tuft: .none, accessory: .none) == "#av-crest-bluejay")
        #expect(tuftRef(.scarlet, tuft: .swoop, accessory: .none) == "#av-tuft-swoop")
        #expect(tuftRef(.scarlet, tuft: .none, accessory: .beanie) == "#av-tuft-none")
        #expect(tuftRef(.scarlet, tuft: .crest, accessory: .gradcap) == "#av-tuft-none")
        #expect(tuftRef(.emerald, tuft: .none, accessory: .none) == "#av-tuft-none")
        #expect(tuftRef(.slate, tuft: .none, accessory: .none) == "#av-tuft-none")
    }

    @Test func crestedSpeciesAreTheOnesWithCrestArt() {
        #expect(AvatarSpecies.cardinal.hasCrest)
        #expect(AvatarSpecies.bluejay.hasCrest)
        #expect(!AvatarSpecies.chickadee.hasCrest)
        #expect(!AvatarSpecies.robin.hasCrest)
        #expect(!AvatarSpecies.starling.hasCrest)
    }

    @Test func displayNamesReadAsWords() {
        #expect(AvatarSpecies.bluejay.displayName == "Blue jay")
        #expect(AvatarSpecies.chickadee.displayName == "Chickadee")
    }

    // MARK: - Drift against the sprite and the palette

    private static func contents(of path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static func symbolIDs(in sprite: String, prefix: String) -> Set<String> {
        Set(
            sprite.matches(of: /id="([a-z-]+)"/).map { String($0.1) }
                .filter { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)) })
    }

    /// One plumage symbol per species and one crest symbol per crested
    /// species, in both directions: a species without art and art without a
    /// species both fail.
    @Test func spriteHasExactlyThePlumageAndCrestsTheSpeciesName() throws {
        let sprite = try Self.contents(of: "Resources/Sprites/avatar-sprite.svg")
        #expect(
            Self.symbolIDs(in: sprite, prefix: "av-plumage-")
                == Set(AvatarSpecies.allCases.map(\.rawValue)))
        #expect(
            Self.symbolIDs(in: sprite, prefix: "av-crest-")
                == Set(AvatarSpecies.allCases.filter(\.hasCrest).map(\.rawValue)))
    }

    /// Every plumage symbol draws the shared skeleton exactly: the body
    /// circle, the two eye discs and the closed beak at their fixed
    /// coordinates, because every expression and accessory is drawn against
    /// them (docs/avatar-species.md, finding 8).
    @Test func everyPlumageSymbolKeepsTheSharedSkeleton() throws {
        let sprite = try Self.contents(of: "Resources/Sprites/avatar-sprite.svg")
        let fixed = [
            #"<circle class="av-body" cx="32" cy="34" r="21"/>"#,
            #"<circle class="av-eyewhite" cx="24.2" cy="29.5" r="7.6"/>"#,
            #"<circle class="av-eyewhite" cx="39.8" cy="29.5" r="7.6"/>"#,
            #"<path class="av-beak" d="M28.6,34.8 H35.4 L32,40.4 Z"/>"#,
        ]
        for species in AvatarSpecies.allCases {
            let start = try #require(
                sprite.range(of: #"<symbol id="av-plumage-\#(species.rawValue)""#),
                "no plumage for \(species)")
            let rest = sprite[start.upperBound...]
            let end = try #require(rest.range(of: "</symbol>"))
            let symbol = rest[..<end.lowerBound]
            for part in fixed {
                #expect(symbol.contains(part), "\(species) plumage changes the skeleton: \(part)")
            }
        }
    }

    /// The six tokens of every colourway are declared in the stylesheet, and
    /// the chickadee's eight carry the tones that were fixed before the
    /// species existed, so no chickadee changed.
    @Test func everyColourwayDeclaresSixTokensAndChickadeesKeepTheirTones() throws {
        let css = try Self.contents(of: "Public/styles.css")
        func value(_ token: String) -> String? {
            guard let range = css.range(of: "\(token):") else { return nil }
            return css[range.upperBound...].prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
        }
        for cap in AvatarCap.allCases {
            for tone in ["cap", "wing", "body", "bib", "beak", "mark"] {
                #expect(value("--avatar-\(cap.rawValue)-\(tone)") != nil, "\(cap) has no \(tone) token")
            }
        }
        for cap in AvatarSpecies.chickadee.colourways {
            #expect(value("--avatar-\(cap.rawValue)-body") == "#F6EFE2")
            #expect(value("--avatar-\(cap.rawValue)-bib") == "#3C4250")
            #expect(value("--avatar-\(cap.rawValue)-beak") == "#E2A33C")
            #expect(value("--avatar-\(cap.rawValue)-mark") == "#F6EFE2")
        }
    }

    /// The white eye disc sits on the cap, so every cap keeps at least 3:1
    /// against white, the rule the palette comment states for the chickadee's
    /// eight. The first fawn and powder caps failed it.
    @Test func everyCapKeepsTheEyeDiscRule() throws {
        let css = try Self.contents(of: "Public/styles.css")
        for cap in AvatarCap.allCases {
            let match = try #require(
                css.firstMatch(of: try Regex("--avatar-\(cap.rawValue)-cap: (#[0-9A-Fa-f]{6})")))
            let ratio = 1.05 / (Self.luminance(String(try #require(match.output[1].substring))) + 0.05)
            #expect(ratio >= 3, "\(cap) cap is \(ratio) against white")
        }
    }

    /// WCAG relative luminance of a six-digit hex colour.
    private static func luminance(_ hex: String) -> Double {
        let digits = hex.dropFirst()
        let channels = stride(from: 0, to: 6, by: 2).map { offset -> Double in
            let start = digits.index(digits.startIndex, offsetBy: offset)
            let raw = Double(Int(digits[start..<digits.index(start, offsetBy: 2)], radix: 16) ?? 0) / 255
            return raw <= 0.03928 ? raw / 12.92 : pow((raw + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }

    /// A dark bird vanishes on a dark backdrop (docs/avatar-species.md,
    /// finding 4). Every colourway's body keeps a lightness step above the
    /// darkest dark-mode backdrop.
    @Test func everyBodyToneStaysAboveTheDarkBackdrops() throws {
        let css = try Self.contents(of: "Public/styles.css")
        // The darkest dark-mode backdrop value declared.
        let darkBackdrops = css.matches(of: /--avatar-back-[a-z]+: (#[0-9A-Fa-f]{6})/)
            .map { Self.luminance(String($0.1)) }
        let darkest = try #require(darkBackdrops.min())
        for cap in AvatarCap.allCases {
            let match = try #require(
                css.firstMatch(of: try Regex("--avatar-\(cap.rawValue)-body: (#[0-9A-Fa-f]{6})")))
            let body = Self.luminance(String(try #require(match.output[1].substring)))
            let ratio = (body + 0.05) / (darkest + 0.05)
            // 1.7 admits the darkest natural tones that still read (crimson,
            // violet and bronze sit near 1.8); the near-black starling the
            // prototype started with scored under 1.0 and vanished.
            #expect(ratio >= 1.7, "\(cap) body is \(ratio) against the darkest backdrop")
        }
    }
}
