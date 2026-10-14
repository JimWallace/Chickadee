import Core
import Foundation
import Testing

/// "Hatch a new bird" in Core: the draw always gives another species and keeps
/// the backdrop and the ring, and the term key groups hatches by Waterloo term.
@Suite struct AvatarHatchTests {

    private static let base = AvatarSpec(
        cap: .teal, wing: .barred, expression: .wink, accessory: .scarf, accent: .honey,
        backdrop: .rose, tuft: .crest, tilt: .left, border: .maple)

    @Test func aHatchAlwaysGivesAnotherSpeciesAndKeepsBackdropAndRing() {
        for species in AvatarSpecies.allCases {
            var current = Self.base
            current.cap = species.colourways[0]
            for seed in UInt64(0)..<1_000 {
                let hatched = AvatarSpec.drawn(excluding: species, keeping: current, fromSeed: seed)
                #expect(hatched.species != species, "seed \(seed) kept the \(species)")
                #expect(hatched.backdrop == current.backdrop)
                #expect(hatched.border == current.border)
                #expect(AvatarSpecies.of(hatched.cap) == hatched.species)
            }
        }
    }

    /// Over many draws, every one of the ten other species comes up.
    @Test func everyOtherSpeciesCanHatch() {
        let seen = Set(
            (UInt64(0)..<1_000).map {
                AvatarSpec.drawn(excluding: .chickadee, keeping: Self.base, fromSeed: $0).species
            })
        #expect(seen == Set(AvatarSpecies.allCases).subtracting([.chickadee]))
    }

    @Test func aSeededHatchIsReproducible() {
        #expect(
            AvatarSpec.drawn(excluding: .robin, keeping: Self.base, fromSeed: 42)
                == AvatarSpec.drawn(excluding: .robin, keeping: Self.base, fromSeed: 42))
    }

    @Test func theTermKeyNamesTheYearAndTheSeason() throws {
        #expect(AvatarHatch.termKey(for: try #require(AcademicTerm(year: 2026, season: .fall))) == "2026-fall")
        #expect(AvatarHatch.termKey(for: try #require(AcademicTerm(year: 2027, season: .winter))) == "2027-winter")
        #expect(AvatarHatch.perTerm == 3)
    }

    /// The current term is read on the Waterloo calendar: 03:00 UTC on
    /// January 1 is still New Year's Eve, Fall, in Waterloo.
    @Test func theCurrentTermUsesWaterlooTime() throws {
        let formatter = ISO8601DateFormatter()
        let newYearUTC = try #require(formatter.date(from: "2027-01-01T03:00:00Z"))
        #expect(AcademicTerm.current(at: newYearUTC) == AcademicTerm(year: 2026, season: .fall))
        let january = try #require(formatter.date(from: "2027-01-15T12:00:00Z"))
        #expect(AcademicTerm.current(at: january) == AcademicTerm(year: 2027, season: .winter))
        #expect(AcademicTerm.current(at: newYearUTC)?.next == AcademicTerm(year: 2027, season: .winter))
    }
}
