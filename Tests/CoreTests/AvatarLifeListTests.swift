// Tests/CoreTests/AvatarLifeListTests.swift
//
// The life list (#2593): the species a student's birds have been, from the
// current bird, the bird before the last hatch and every recorded hatch, and
// the standing bird drawn for each species.

import Testing

@testable import Core

@Suite struct AvatarLifeListTests {

    @Test func aStudentWhoNeverHatchedHasSeenOneSpecies() {
        #expect(AvatarLifeList.seen(current: .robin, previous: nil, hatches: []) == [.robin])
    }

    @Test func everyRecordedHatchAddsBothItsSpecies() {
        let seen = AvatarLifeList.seen(
            current: .dove, previous: .junco,
            hatches: [(from: .chickadee, to: .junco), (from: .junco, to: .dove)])
        #expect(seen == [.chickadee, .junco, .dove])
    }

    /// A hatch row made before species were recorded adds nothing: no
    /// species is guessed.
    @Test func anUnrecordedHatchAddsNothing() {
        let seen = AvatarLifeList.seen(current: .cardinal, previous: nil, hatches: [(from: nil, to: nil)])
        #expect(seen == [.cardinal])
    }

    @Test func noBirdHasNoList() {
        #expect(AvatarLifeList.seen(current: nil, previous: nil, hatches: []).isEmpty)
    }

    @Test(arguments: AvatarSpecies.allCases)
    func eachSpeciesStandingBirdIsThatSpeciesPlainAndBare(species: AvatarSpecies) {
        let bird = AvatarLifeList.bird(for: species)
        #expect(bird.species == species)
        #expect(bird.accessory == .none)
        #expect(bird.tilt == .upright)
        #expect(bird.border == .none)
    }
}
