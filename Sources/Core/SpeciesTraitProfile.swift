// Core/SpeciesTraitProfile.swift
//
// How a species leans in the first-use draw (docs/avatar-species.md, "Trait
// map"). A profile weights the head, the wing pattern and the expression per
// species: a jay leans to barred wings and a keen look, a dove to a plain
// wing and a sleepy one. A weight changes only what the draw picks, so no
// stored bird changes, and every stored value still renders.

/// The weights one species draws with. A weight of zero means the draw never
/// picks that option for this species; the option stays valid when stored.
public struct SpeciesTraitProfile: Sendable, Equatable {
    /// `none` is the bare head, which on a crested species is its swept crest.
    public let tuft: [AvatarTuft: Int]
    public let wing: [AvatarWing: Int]
    /// Starter expressions only; an unlockable never has a weight.
    public let expression: [AvatarExpression: Int]

    public init(tuft: [AvatarTuft: Int], wing: [AvatarWing: Int], expression: [AvatarExpression: Int]) {
        self.tuft = tuft
        self.wing = wing
        self.expression = expression
    }

    /// The head weights of a species with no crest: bare three times in four,
    /// and one of the four feather tufts as a rare quirk.
    public static let bareHead: [AvatarTuft: Int] = [.none: 12, .cowlick: 1, .crest: 1, .pair: 1, .swoop: 1]

    /// The head weights of a crested species: the swept crest (`none`) two
    /// times in three, else raised (`crest`) or relaxed (`cowlick`). The two
    /// generic shapes that map onto a crest variant are never drawn for it.
    public static let crestedHead: [AvatarTuft: Int] = [.none: 4, .crest: 1, .cowlick: 1, .pair: 0, .swoop: 0]

    /// Every expression equally likely.
    public static let evenExpression: [AvatarExpression: Int] = Dictionary(
        uniqueKeysWithValues: AvatarExpression.starterCases.map { ($0, 1) })
}

extension AvatarSpecies {
    /// The species' lean in the draw. The head follows `hasCrest`, so
    /// "crested" has one source; the wing and the expression are per species.
    /// The chickadee is the one species with no lean at all: it is the bird
    /// every stored avatar already is.
    public var traits: SpeciesTraitProfile {
        let head = hasCrest ? SpeciesTraitProfile.crestedHead : SpeciesTraitProfile.bareHead
        return switch self {
        case .chickadee:
            SpeciesTraitProfile(
                tuft: head,
                wing: [.plain: 1, .barred: 1, .tipped: 1, .speckled: 1, .edged: 1, .twotone: 1],
                expression: SpeciesTraitProfile.evenExpression)
        case .cardinal:
            SpeciesTraitProfile(
                tuft: head,
                wing: [.plain: 3, .barred: 1, .tipped: 1, .speckled: 1, .edged: 2, .twotone: 1],
                expression: [.bright: 3, .sleepy: 1, .wink: 1, .curious: 1, .keen: 2, .intrigued: 1])
        case .robin:
            SpeciesTraitProfile(
                tuft: head,
                wing: [.plain: 3, .barred: 1, .tipped: 1, .speckled: 1, .edged: 2, .twotone: 2],
                expression: [.bright: 2, .sleepy: 1, .wink: 1, .curious: 2, .keen: 1, .intrigued: 2])
        case .bluejay:
            SpeciesTraitProfile(
                tuft: head,
                wing: [.plain: 1, .barred: 4, .tipped: 1, .speckled: 1, .edged: 1, .twotone: 1],
                expression: [.bright: 1, .sleepy: 1, .wink: 2, .curious: 2, .keen: 3, .intrigued: 1])
        case .starling:
            SpeciesTraitProfile(
                tuft: head,
                wing: [.plain: 1, .barred: 1, .tipped: 1, .speckled: 4, .edged: 1, .twotone: 1],
                expression: [.bright: 1, .sleepy: 1, .wink: 2, .curious: 2, .keen: 1, .intrigued: 1])
        case .goldfinch:
            SpeciesTraitProfile(
                tuft: head,
                wing: [.plain: 1, .barred: 4, .tipped: 1, .speckled: 1, .edged: 1, .twotone: 1],
                expression: [.bright: 3, .sleepy: 1, .wink: 1, .curious: 1, .keen: 1, .intrigued: 2])
        case .blackbird:
            SpeciesTraitProfile(
                tuft: head,
                wing: [.plain: 3, .barred: 1, .tipped: 1, .speckled: 1, .edged: 2, .twotone: 1],
                expression: [.bright: 1, .sleepy: 1, .wink: 1, .curious: 1, .keen: 3, .intrigued: 1])
        case .waxwing:
            SpeciesTraitProfile(
                tuft: head,
                wing: [.plain: 1, .barred: 1, .tipped: 4, .speckled: 1, .edged: 2, .twotone: 1],
                expression: [.bright: 2, .sleepy: 2, .wink: 1, .curious: 1, .keen: 1, .intrigued: 2])
        case .junco:
            SpeciesTraitProfile(
                tuft: head,
                wing: [.plain: 3, .barred: 1, .tipped: 1, .speckled: 1, .edged: 2, .twotone: 2],
                expression: [.bright: 2, .sleepy: 1, .wink: 1, .curious: 2, .keen: 1, .intrigued: 1])
        case .sparrow:
            SpeciesTraitProfile(
                tuft: head,
                wing: [.plain: 1, .barred: 3, .tipped: 1, .speckled: 2, .edged: 1, .twotone: 1],
                expression: [.bright: 2, .sleepy: 1, .wink: 1, .curious: 2, .keen: 1, .intrigued: 1])
        case .dove:
            SpeciesTraitProfile(
                tuft: head,
                wing: [.plain: 4, .barred: 1, .tipped: 1, .speckled: 1, .edged: 1, .twotone: 1],
                expression: [.bright: 2, .sleepy: 3, .wink: 1, .curious: 1, .keen: 1, .intrigued: 1])
        }
    }
}
