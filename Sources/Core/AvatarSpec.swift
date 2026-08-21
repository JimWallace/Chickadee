// Core/AvatarSpec.swift
//
// What a generated student chickadee IS: five slot choices, not an image and
// not a seed.  See docs/student-avatars.md for why the spec is the stored
// artifact — the short version is that re-deriving from a seed on every render
// means appending one option to one slot reshuffles every existing avatar.

/// The cap, bib and (via its family) the wing and beak.  The strongest identity
/// signal at any size, which is why it is the widest slot.
public enum AvatarCap: String, CaseIterable, Codable, Sendable {
    case slate, plum, forest, indigo, rust, teal, umber, ink
}

/// The two cheek patches, and the marks on a patterned wing.
public enum AvatarCheek: String, CaseIterable, Codable, Sendable {
    case snow, cream, ivory, mint
}

/// The belly the bird sits on.
public enum AvatarFlank: String, CaseIterable, Codable, Sendable {
    case sand, wheat, moss, mist, blush, stone
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
    public var cheek: AvatarCheek
    public var flank: AvatarFlank
    public var backdrop: AvatarBackdrop
    public var wing: AvatarWing

    public init(
        cap: AvatarCap,
        cheek: AvatarCheek,
        flank: AvatarFlank,
        backdrop: AvatarBackdrop,
        wing: AvatarWing
    ) {
        self.cap = cap
        self.cheek = cheek
        self.flank = flank
        self.backdrop = backdrop
        self.wing = wing
    }

    /// Every distinct bird the colour slots can produce.
    public static var combinationCount: Int {
        AvatarCap.allCases.count * AvatarCheek.allCases.count * AvatarFlank.allCases.count
            * AvatarBackdrop.allCases.count * AvatarWing.allCases.count
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
    public static func drawn<G: RandomNumberGenerator>(using generator: inout G) -> AvatarSpec {
        AvatarSpec(
            cap: pick(using: &generator),
            cheek: pick(using: &generator),
            flank: pick(using: &generator),
            backdrop: pick(using: &generator),
            wing: pick(using: &generator)
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
