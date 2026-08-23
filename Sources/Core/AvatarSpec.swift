// Core/AvatarSpec.swift
//
// What a generated student chickadee IS: five slot choices, not an image and
// not a seed.  See docs/student-avatars.md for why the spec is the stored
// artifact — the short version is that re-deriving from a seed on every render
// means appending one option to one slot reshuffles every existing avatar.

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
public enum AvatarExpression: String, CaseIterable, Codable, Sendable {
    case bright, sleepy, wink, curious, keen, startled
}

/// Where the personality actually lives.  `none` is a real option, not an
/// absence: most birds wear nothing.
public enum AvatarAccessory: String, CaseIterable, Codable, Sendable {
    case none, scarf, headphones, beanie, glasses, gradcap, bowtie, bloom
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

    public init(
        cap: AvatarCap,
        wing: AvatarWing,
        expression: AvatarExpression,
        accessory: AvatarAccessory,
        accent: AvatarAccent,
        backdrop: AvatarBackdrop
    ) {
        self.cap = cap
        self.wing = wing
        self.expression = expression
        self.accessory = accessory
        self.accent = accent
        self.backdrop = backdrop
    }

    /// Every distinct bird the five axes can produce.
    public static var combinationCount: Int {
        AvatarCap.allCases.count * AvatarWing.allCases.count * AvatarExpression.allCases.count
            * AvatarAccessory.allCases.count * AvatarAccent.allCases.count
            * AvatarBackdrop.allCases.count
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

    /// A fresh bird, drawn uniformly from every slot.
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
            expression: pick(using: &generator),
            accessory: pick(using: &generator),
            accent: pick(using: &generator),
            backdrop: pick(using: &generator)
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

    private static func pick<T: CaseIterable, G: RandomNumberGenerator>(
        using generator: inout G
    ) -> T where T.AllCases.Index == Int {
        let all = T.allCases
        return all[Int.random(in: 0..<all.count, using: &generator)]
    }
}
