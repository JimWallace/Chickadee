// Core/AvatarSpec.swift
//
// What a generated student chickadee IS: seven slot choices, not an image and
// not a seed.  See docs/student-avatars.md for why the spec is the stored
// artifact — the short version is that re-deriving from a seed on every render
// means appending one option to one slot reshuffles every existing avatar.

import Foundation

/// The cap and, via its family, the wing beside it.  The loudest axis, which is
/// why it carries the least detail.
///
/// Body, cheek, beak and bib are NOT axes: they are fixed, and they are what
/// keeps every bird a chickadee even when the cap goes plum.
public enum AvatarCap: String, CaseIterable, Codable, Sendable {
    case slate, plum, forest, indigo, rust, teal, umber, ink
}

/// How the bird looks out of the page — the axis that reads first and from
/// furthest away.
///
/// Append only: a stored spec names a case by its raw value, so a case that is
/// renamed, reordered or removed changes or breaks a student's bird.
public enum AvatarExpression: String, CaseIterable, Codable, Sendable {
    case bright, sleepy, wink, curious, keen, startled
    /// The first wardrobe unlocks (docs/student-avatars.md, decision 5): new
    /// options arrive as something to earn, so the first-use draw never
    /// yields these three. See `starterCases`.
    case chirp, sly, dreamy

    /// The expressions a first-use draw picks from. Every case appended after
    /// the first six is an unlockable and is NOT in this list.
    public static let starterCases: [AvatarExpression] = [
        .bright, .sleepy, .wink, .curious, .keen, .startled,
    ]
}

/// Where the personality actually lives.  `none` is a real option, not an
/// absence: most birds wear nothing.
public enum AvatarAccessory: String, CaseIterable, Codable, Sendable {
    case none, scarf, headphones, beanie, glasses, gradcap, bowtie, bloom
    /// Replaced the gradcap in the first-use draw, which is now kept for a
    /// later completion achievement (docs/student-wardrobe.md, decision 4).
    case headband

    /// The accessories a first-use draw picks from. The gradcap is NOT in this
    /// list: it reads as "graduated", so it is kept as an earned item.
    public static let starterCases: [AvatarAccessory] = [
        .none, .scarf, .headphones, .beanie, .glasses, .headband, .bowtie, .bloom,
    ]

    /// A hat that replaces the tuft: a bird wears one or the other, never
    /// both. The gradcap's board let a tuft stick up through it, which looked
    /// wrong; the beanie covers every tuft anyway. The rule is applied at
    /// render time, so the stored tuft is kept and comes back if the
    /// accessory changes.
    public var hidesTuft: Bool {
        switch self {
        case .beanie, .gradcap: true
        case .none, .scarf, .headphones, .glasses, .bowtie, .bloom, .headband: false
        }
    }
}

/// The colour an accessory is drawn in.  Part of the accessory axis rather
/// than an axis of its own — the design counts it that way ("8 + 5 accents"),
/// and the arithmetic only reaches 92,160 birds if it multiplies.
public enum AvatarAccent: String, CaseIterable, Codable, Sendable {
    case ember, orchid, lagoon, honey, moss
}

/// The disc behind the bird.  The one slot with a dark-mode mirror.
public enum AvatarBackdrop: String, CaseIterable, Codable, Sendable {
    case sky, rose, sage, lilac, peach, aqua, straw, pebble
}

/// The wing pattern — the one slot that is geometry rather than colour, and
/// the cheapest of those because all six share a single wing outline.
///
/// A raw value names a `<symbol>` in `Resources/Views/_avatar-sprite.leaf`
/// (`av-wing-<rawValue>`); `AvatarSpriteDriftTests` asserts the two sets match
/// in BOTH directions, so neither a case without art nor art without a case
/// can ship.
public enum AvatarWing: String, CaseIterable, Codable, Sendable {
    case plain, barred, tipped, speckled, edged, twotone
}

/// The ring a student chose to wear around the disc. Chosen on the account
/// page and never drawn: every bird starts with `none`
/// (docs/student-wardrobe.md, decisions 1 and 2).
///
/// Append only. The five colour cases name an `AvatarAccent`, whose palette
/// token colours a solid ring. The cases after them are patterned rings, each
/// with its own art (`ring`). The staff ring is deliberately NOT a case: it is
/// drawn from a course role, so no student can store it.
public enum AvatarBorder: String, CaseIterable, Codable, Sendable {
    case none, ember, orchid, lagoon, honey, moss
    /// Six flat bands, red to violet. A starter ring anyone may choose.
    case rainbow
    /// Five flat bands in the accessory accents. A special reward.
    case spectrum
    /// The student's accent and cap colour, half each. An earned reward.
    case twotone
    /// The student's accent with a line of stitches. An earned reward.
    case stitched

    /// The accent this ring is drawn in; nil for `none` and the patterned rings.
    public var accent: AvatarAccent? { AvatarAccent(rawValue: rawValue) }

    /// The art this choice draws.
    public var ring: AvatarRing {
        switch self {
        case .none: .none
        case .ember, .orchid, .lagoon, .honey, .moss: .solid
        case .rainbow: .rainbow
        case .spectrum: .spectrum
        case .twotone: .twotone
        case .stitched: .stitched
        }
    }

    /// The name a student reads in the picker.
    public var displayName: String {
        switch self {
        case .twotone: "Two-tone"
        default: rawValue.capitalized
        }
    }

    /// Who may wear it. Only `starter` rings can be chosen until unlocks exist
    /// (docs/student-wardrobe.md, slice W3); the others show as locked.
    public var availability: AvatarAvailability {
        switch self {
        case .none, .ember, .orchid, .lagoon, .honey, .moss, .rainbow: .starter
        case .twotone, .stitched: .earned
        case .spectrum: .special
        }
    }
}

/// How a wardrobe option is obtained (docs/student-wardrobe.md, "Rings").
public enum AvatarAvailability: String, CaseIterable, Codable, Sendable {
    /// Open to every student.
    case starter
    /// Unlocked by a lab achievement.
    case earned
    /// Unlocked by a course-level achievement, such as completing the course.
    case special
}

/// The drawn ring: one `<symbol>` each in the sprite (`av-ring-<rawValue>`),
/// drawn on top of the bird and outside the tilt, so a patterned ring keeps its
/// orientation. Append only.
///
/// `staff` is reserved: it is drawn for course staff from their role, it is no
/// `AvatarBorder`'s ring, and its double shape and colour belong to no student
/// option (docs/student-wardrobe.md, "The staff ring").
public enum AvatarRing: String, CaseIterable, Codable, Sendable {
    case none, solid, rainbow, spectrum, twotone, stitched, staff
}

/// A feather tuft on top of the head — the one axis that changes the
/// outline of a bird without a hat, which is the feature that still reads at
/// roster size.  `none` is a real option.
///
/// A raw value names a `<symbol>` in the sprite (`av-tuft-<rawValue>`), with
/// the same both-directions drift test as `AvatarWing`.
public enum AvatarTuft: String, CaseIterable, Codable, Sendable {
    case none, cowlick, crest, pair, swoop
}

/// How far the whole bird leans. Not a symbol: one rotate transform on the
/// group that holds every layer except the backdrop, about the body centre.
public enum AvatarTilt: String, CaseIterable, Codable, Sendable {
    case upright, left, right

    /// Degrees, clockwise positive (the SVG convention).
    public var degrees: Int {
        switch self {
        case .upright: 0
        case .left: -9
        case .right: 9
        }
    }
}

/// One student's bird.
///
/// `Codable` with string raw values so the stored form is legible in a JSON
/// column and survives a slot gaining options.  `var` rather than `let`
/// throughout because customization mutates one slot at a time.  `Hashable`
/// so a set of specs is expressible — useful for counting distinct birds, and
/// deliberately NOT used as a uniqueness key: see docs/student-avatars.md on
/// why uniqueness is carried by a per-course handle instead.
public struct AvatarSpec: Codable, Sendable, Hashable {
    public var cap: AvatarCap
    public var wing: AvatarWing
    public var expression: AvatarExpression
    public var accessory: AvatarAccessory
    /// The accessory's colour. Drawn even when `accessory` is `.none`, so
    /// putting one on later does not need a second draw.
    public var accent: AvatarAccent
    public var backdrop: AvatarBackdrop
    public var tuft: AvatarTuft
    public var tilt: AvatarTilt
    /// Chosen by the student, never drawn. Not part of `combinationCount`.
    public var border: AvatarBorder

    public init(
        cap: AvatarCap,
        wing: AvatarWing,
        expression: AvatarExpression,
        accessory: AvatarAccessory,
        accent: AvatarAccent,
        backdrop: AvatarBackdrop,
        tuft: AvatarTuft = .none,
        tilt: AvatarTilt = .upright,
        border: AvatarBorder = .none
    ) {
        self.cap = cap
        self.wing = wing
        self.expression = expression
        self.accessory = accessory
        self.accent = accent
        self.backdrop = backdrop
        self.tuft = tuft
        self.tilt = tilt
        self.border = border
    }

    /// Every distinct bird the drawn axes can produce, unlockables included.
    /// The border is chosen, not drawn, so it is not counted.
    public static var combinationCount: Int {
        combinations(
            expressions: AvatarExpression.allCases.count,
            accessories: AvatarAccessory.allCases.count)
    }

    /// Every distinct bird a first-use draw can produce. This is the number to
    /// quote: it is what a class of new students is drawn from.
    public static var starterCombinationCount: Int {
        combinations(
            expressions: AvatarExpression.starterCases.count,
            accessories: AvatarAccessory.starterCases.count)
    }

    private static func combinations(expressions: Int, accessories: Int) -> Int {
        AvatarCap.allCases.count * AvatarWing.allCases.count * expressions
            * accessories * AvatarAccent.allCases.count
            * AvatarBackdrop.allCases.count * AvatarTuft.allCases.count
            * AvatarTilt.allCases.count
    }
}

// MARK: - Decoding

extension AvatarSpec {
    private enum CodingKeys: String, CodingKey {
        case cap, wing, expression, accessory, accent, backdrop, tuft, tilt, border
    }

    /// Specs stored before the tuft and tilt axes existed have neither key.
    /// They decode to `.none` / `.upright`; `missingAxes(inStoredJSON:)` is how
    /// the store tells such a spec apart from one that chose those values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.cap = try container.decode(AvatarCap.self, forKey: .cap)
        self.wing = try container.decode(AvatarWing.self, forKey: .wing)
        self.expression = try container.decode(AvatarExpression.self, forKey: .expression)
        self.accessory = try container.decode(AvatarAccessory.self, forKey: .accessory)
        self.accent = try container.decode(AvatarAccent.self, forKey: .accent)
        self.backdrop = try container.decode(AvatarBackdrop.self, forKey: .backdrop)
        self.tuft = try container.decodeIfPresent(AvatarTuft.self, forKey: .tuft) ?? .none
        self.tilt = try container.decodeIfPresent(AvatarTilt.self, forKey: .tilt) ?? .upright
        // A spec stored before the border existed has no border, which is
        // exactly `none`: the border is chosen, so there is nothing to fill.
        self.border = try container.decodeIfPresent(AvatarBorder.self, forKey: .border) ?? .none
    }
}

/// An axis added after specs were first stored. A spec saved before the axis
/// existed has no value for it, which is different from choosing its default.
public enum AvatarLateAxis: String, CaseIterable, Sendable {
    case tuft, tilt
}

extension AvatarSpec {
    /// The late axes `json` carries no key for. Empty for a current spec and
    /// for JSON that is not an object.
    public static func missingAxes(inStoredJSON json: String) -> Set<AvatarLateAxis> {
        guard let data = json.data(using: .utf8),
            let probe = try? JSONDecoder().decode(LateAxisProbe.self, from: data)
        else { return [] }
        var missing: Set<AvatarLateAxis> = []
        if !probe.hasTuft { missing.insert(.tuft) }
        if !probe.hasTilt { missing.insert(.tilt) }
        return missing
    }

    /// Reads only whether each late key is PRESENT, not its value: a value
    /// that no longer decodes is the full decoder's problem, not this one's.
    private struct LateAxisProbe: Decodable {
        let hasTuft: Bool
        let hasTilt: Bool

        private enum CodingKeys: String, CodingKey { case tuft, tilt }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hasTuft = container.contains(.tuft)
            hasTilt = container.contains(.tilt)
        }
    }

    /// This spec with a fresh random value in each of `axes` and every other
    /// slot unchanged. A draw into an empty slot, not a reshuffle.
    public func fillingMissing<G: RandomNumberGenerator>(
        _ axes: Set<AvatarLateAxis>, using generator: inout G
    ) -> AvatarSpec {
        var filled = self
        if axes.contains(.tuft) { filled.tuft = Self.pick(using: &generator) }
        if axes.contains(.tilt) { filled.tilt = Self.pick(using: &generator) }
        return filled
    }

    /// `fillingMissing(_:using:)` with the system RNG — the production path.
    public func fillingMissing(_ axes: Set<AvatarLateAxis>) -> AvatarSpec {
        var generator = SystemRandomNumberGenerator()
        return fillingMissing(axes, using: &generator)
    }
}

// MARK: - Drawing

/// SplitMix64 — a deterministic generator for the one-time draw and for tests.
///
/// Deliberately small and self-contained: the draw has to be reproducible from
/// a seed in a test without depending on the platform's RNG, and SplitMix64 is
/// the standard answer at this size.  It is NOT a security primitive and holds
/// nothing secret; the seed it consumes is not an identifier.
public struct AvatarSeedGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { self.state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension AvatarSpec {

    /// A fresh bird, drawn uniformly from every slot's starter options.
    ///
    /// - Important: call this ONCE per student, at first use, and store the
    ///   result.  There is deliberately no `spec(forSeed:)` convenience that a
    ///   render path could reach for: re-deriving per render is what makes
    ///   appending an option reshuffle everybody, and a convenience for it
    ///   would be an invitation.
    ///
    ///   Nor is the seed ever an identifier.  A spec derived from a username
    ///   is reproducible by anyone who knows the username, which would let any
    ///   classmate compute a target's bird offline — private-looking and not
    ///   private.  The stored value is drawn from the system RNG and has no
    ///   connection to who the student is.
    public static func drawn<G: RandomNumberGenerator>(using generator: inout G) -> AvatarSpec {
        AvatarSpec(
            cap: pick(using: &generator),
            wing: pick(using: &generator),
            expression: pick(from: AvatarExpression.starterCases, using: &generator),
            accessory: pick(from: AvatarAccessory.starterCases, using: &generator),
            accent: pick(using: &generator),
            backdrop: pick(using: &generator),
            tuft: pick(using: &generator),
            tilt: pick(using: &generator)
        )
    }

    /// A fresh bird from the system's RNG — the production first-use path.
    public static func drawn() -> AvatarSpec {
        var generator = SystemRandomNumberGenerator()
        return drawn(using: &generator)
    }

    /// A fresh bird reproducible from `seed`.  For tests, fixtures and preview
    /// sheets; see the note on `drawn(using:)` about not rendering from it.
    public static func drawn(fromSeed seed: UInt64) -> AvatarSpec {
        var generator = AvatarSeedGenerator(seed: seed)
        return drawn(using: &generator)
    }

    fileprivate static func pick<T: CaseIterable, G: RandomNumberGenerator>(
        using generator: inout G
    ) -> T where T.AllCases.Index == Int {
        pick(from: Array(T.allCases), using: &generator)
    }

    private static func pick<T, G: RandomNumberGenerator>(
        from options: [T], using generator: inout G
    ) -> T {
        options[Int.random(in: 0..<options.count, using: &generator)]
    }
}
