// Core/AvatarSpecies.swift
//
// Which bird a student's avatar is. Every species shares one skeleton: the
// body circle, the eye discs, the beak, the wings, the expressions, the
// accessories, the tufts, the backdrops and the rings. A species owns its
// plumage art and its colourways, and nothing else. See
// docs/avatar-species.md.

/// The bird. Append only: a species is never renamed, reordered or removed.
///
/// A species is not stored. It is derived from the colourway (`AvatarCap`)
/// by `of(_:)`, a switch the compiler keeps total, so each colourway belongs
/// to exactly one species. So a spec stored before any
/// species but the chickadee existed names a chickadee colourway and IS a
/// chickadee, with no key to fill and no migration to run.
public enum AvatarSpecies: String, CaseIterable, Codable, Sendable {
    case chickadee, cardinal, robin, bluejay, starling
    /// The second set (docs/avatar-species.md, A3): the American goldfinch,
    /// the red-winged blackbird, the cedar waxwing, the dark-eyed junco, the
    /// song sparrow and the mourning dove.
    case goldfinch, blackbird, waxwing, junco, sparrow, dove

    /// The colourways a bird of this species may wear, in `AvatarCap` order.
    /// The chickadee keeps its eight, four of them frankly artificial, because
    /// its markings carry the species. The other species get natural tones
    /// only: for a cardinal the colour IS the species, so a plum cardinal is
    /// not a cardinal.
    public var colourways: [AvatarCap] {
        AvatarCap.allCases.filter { AvatarSpecies.of($0) == self }
    }

    /// A crested species draws `av-crest-<species>` in the tuft layer when
    /// the bird wears no tuft, and a hat hides it like any tuft
    /// (docs/avatar-species.md, finding 5).
    public var hasCrest: Bool {
        switch self {
        case .cardinal, .bluejay, .waxwing: true
        case .chickadee, .robin, .starling, .goldfinch, .blackbird, .junco, .sparrow, .dove: false
        }
    }

    /// The name a student reads.
    public var displayName: String {
        switch self {
        case .bluejay: "Blue jay"
        case .sparrow: "Song sparrow"
        case .dove: "Mourning dove"
        default: rawValue.capitalized
        }
    }

    /// The species a colourway belongs to. A `switch`, so a new `AvatarCap`
    /// case does not compile until it has a species.
    public static func of(_ cap: AvatarCap) -> AvatarSpecies {
        switch cap {
        case .slate, .plum, .forest, .indigo, .rust, .teal, .umber, .ink: .chickadee
        case .scarlet, .crimson, .fawn: .cardinal
        case .copper, .brick, .apricot: .robin
        case .azure, .cobalt, .powder: .bluejay
        case .emerald, .violet, .bronze: .starling
        case .lemon, .saffron, .olive: .goldfinch
        case .jet, .onyx, .ebony: .blackbird
        case .cedar, .taupe, .sand: .waxwing
        case .pewter, .graphite, .dusk: .junco
        case .chestnut, .sepia, .hazel: .sparrow
        case .oat, .mauve, .ash: .dove
        }
    }
}
