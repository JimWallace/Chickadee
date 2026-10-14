// Tests/CoreTests/SpeciesTraitProfileTests.swift

import Core
import Testing

/// Each species leans in the draw (docs/avatar-species.md, "Trait map"): a
/// profile weights the head, the wing pattern and the expression. A weight
/// changes what the draw picks and nothing a stored bird shows.
@Suite struct SpeciesTraitProfileTests {

    @Test(arguments: AvatarSpecies.allCases)
    func everyProfileHasSomethingToDrawInEverySlot(species: AvatarSpecies) {
        let traits = species.traits
        #expect(traits.tuft.values.contains { $0 > 0 }, "\(species) has no head to draw")
        #expect(traits.wing.values.contains { $0 > 0 }, "\(species) has no wing to draw")
        #expect(traits.expression.values.contains { $0 > 0 }, "\(species) has no expression to draw")
        #expect(traits.tuft.values.allSatisfy { $0 >= 0 })
        #expect(traits.wing.values.allSatisfy { $0 >= 0 })
        #expect(traits.expression.values.allSatisfy { $0 >= 0 })
        // Every starter expression is weighted and no unlockable is.
        #expect(Set(traits.expression.keys) == Set(AvatarExpression.starterCases))
        #expect(Set(traits.wing.keys) == Set(AvatarWing.allCases))
        #expect(Set(traits.tuft.keys) == Set(AvatarTuft.allCases))
    }

    /// No option disappears from the flock: each tuft, wing and expression
    /// has a positive weight in at least one species.
    @Test func everyOptionIsDrawnBySomeSpecies() {
        let all = AvatarSpecies.allCases
        for tuft in AvatarTuft.allCases {
            #expect(all.contains { ($0.traits.tuft[tuft] ?? 0) > 0 }, "\(tuft) is drawn by no species")
        }
        for wing in AvatarWing.allCases {
            #expect(all.contains { ($0.traits.wing[wing] ?? 0) > 0 }, "\(wing) is drawn by no species")
        }
        for expression in AvatarExpression.starterCases {
            #expect(
                all.contains { ($0.traits.expression[expression] ?? 0) > 0 },
                "\(expression) is drawn by no species")
        }
    }

    /// A crested species draws its head from the crest shapes only, and a
    /// bare-headed species is bare most of the time.
    @Test(arguments: AvatarSpecies.allCases)
    func theHeadFollowsTheCrest(species: AvatarSpecies) {
        let tuft = species.traits.tuft
        if species.hasCrest {
            #expect(tuft == SpeciesTraitProfile.crestedHead)
            #expect(tuft[.pair] == 0 && tuft[.swoop] == 0)
            #expect((tuft[.none] ?? 0) > (tuft[.crest] ?? 0))
        } else {
            #expect(tuft == SpeciesTraitProfile.bareHead)
            let total = tuft.values.reduce(0, +)
            #expect(Double(tuft[.none] ?? 0) / Double(total) >= 0.7)
        }
    }

    /// Every tuft maps to one crest shape, so a stored tuft on a crested
    /// bird always renders as a crest, and every shape is reachable.
    @Test func everyTuftMapsToACrestShapeAndEveryShapeIsReachable() {
        var shapes: Set<AvatarCrestShape> = []
        for tuft in AvatarTuft.allCases { shapes.insert(AvatarCrestShape(tuft: tuft)) }
        #expect(shapes == Set(AvatarCrestShape.allCases))
        #expect(AvatarCrestShape(tuft: .none) == .swept)
        // The draw can reach every shape on a crested species.
        for shape in AvatarCrestShape.allCases {
            #expect(
                AvatarTuft.allCases.contains {
                    AvatarCrestShape(tuft: $0) == shape && (SpeciesTraitProfile.crestedHead[$0] ?? 0) > 0
                }, "\(shape) is never drawn")
        }
    }

    /// The lean shows in the draw: a jay is barred more often than plain, a
    /// starling speckled, a dove sleepy more often than keen.
    @Test func theDrawFollowsTheProfiles() {
        var counts: [AvatarSpecies: [AvatarWing: Int]] = [:]
        var expressions: [AvatarSpecies: [AvatarExpression: Int]] = [:]
        for seed in 0..<20_000 as Range<UInt64> {
            let spec = AvatarSpec.drawn(fromSeed: seed)
            counts[spec.species, default: [:]][spec.wing, default: 0] += 1
            expressions[spec.species, default: [:]][spec.expression, default: 0] += 1
        }
        #expect((counts[.bluejay]?[.barred] ?? 0) > 2 * (counts[.bluejay]?[.plain] ?? 0))
        #expect((counts[.starling]?[.speckled] ?? 0) > 2 * (counts[.starling]?[.plain] ?? 0))
        #expect((counts[.dove]?[.plain] ?? 0) > 2 * (counts[.dove]?[.barred] ?? 0))
        #expect((expressions[.dove]?[.sleepy] ?? 0) > 2 * (expressions[.dove]?[.keen] ?? 0))
        #expect((expressions[.bluejay]?[.keen] ?? 0) > 2 * (expressions[.bluejay]?[.sleepy] ?? 0))
        // The chickadee has no lean.
        let chickadee = counts[.chickadee] ?? [:]
        let mean = Double(chickadee.values.reduce(0, +)) / Double(AvatarWing.allCases.count)
        for wing in AvatarWing.allCases {
            #expect(abs(Double(chickadee[wing] ?? 0) - mean) < mean * 0.25, "\(wing)")
        }
    }

    /// A species with its own wing art draws it for that pattern only; every
    /// other pattern, and every other species, draws the shared symbol.
    @Test func wingArtIsUsedForItsPatternOnly() {
        func wingRef(_ cap: AvatarCap, _ wing: AvatarWing) -> String {
            let spec = AvatarSpec(
                cap: cap, wing: wing, expression: .bright, accessory: .none, accent: .ember, backdrop: .sky)
            return AvatarPresentation(for: spec, size: .standard, accessibility: .decorative, isStaff: false)
                .wingSymbolRef
        }
        #expect(wingRef(.azure, .barred) == "#av-wing-bluejay-barred")
        #expect(wingRef(.lemon, .barred) == "#av-wing-goldfinch-barred")
        #expect(wingRef(.azure, .plain) == "#av-wing-plain")
        #expect(wingRef(.scarlet, .barred) == "#av-wing-barred")
        #expect(wingRef(.slate, .barred) == "#av-wing-barred")
    }
}
