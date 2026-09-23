// Tests/CoreTests/TournamentStandingsTests.swift
//
// The Swiss standings order and the rematch fallback, on hand-built slots.
// `TournamentPairingTests` plays whole tournaments with the higher seed
// always winning, so points order and seed order agree in every case it
// runs, and the mutation sweep of 2026-09-22 (#1574) showed that nothing
// could tell whether points or byes took part in the ranking at all. These
// tests pin each tie-break on its own, with the seeds arranged against it.

import Testing

@testable import Core

@Suite struct TournamentStandingsTests {

    /// Points rank first, even against the seed order. Seed 3 beat seed 1,
    /// so seed 3 leads on one point. Mutating `a.points != b.points` to
    /// `==` ranked by seed alone and put seed 1 first.
    @Test func morePointsRankAboveABetterSeed() {
        let completed = [TournamentSlot(round: 1, position: 0, homeSeed: 1, awaySeed: 3, winnerSeed: 3)]
        let standings = TournamentPairing.swissStandings(entrantCount: 3, completed: completed)
        #expect(standings.map(\.seed) == [3, 1, 2])
        #expect(standings.map(\.points) == [1, 0, 0])
    }

    /// On equal points, fewer byes rank first, even against the seed order.
    /// Seed 1 has its point from a bye and seed 2 won a match, so seed 2
    /// leads. Mutating `a.byes != b.byes` to `==` skipped the byes and put
    /// seed 1 first.
    @Test func onEqualPointsFewerByesRankAboveABetterSeed() {
        let completed = [
            TournamentSlot(round: 1, position: 0, homeSeed: 1, awaySeed: nil, winnerSeed: 1),
            TournamentSlot(round: 1, position: 1, homeSeed: 2, awaySeed: 3, winnerSeed: 2),
        ]
        let standings = TournamentPairing.swissStandings(entrantCount: 3, completed: completed)
        #expect(standings.map(\.seed) == [2, 1, 3])
        #expect(standings.map(\.points) == [1, 1, 0])
        #expect(standings.map(\.byes) == [0, 1, 0])
    }

    /// When every pair has met, no rematch-free pairing exists and the
    /// greedy fallback must still pair everybody. Mutating
    /// `unpaired.count >= 2` to `<` made the fallback return no pairs, so
    /// the round had nobody in it.
    @Test func whenEveryPairHasMetTheFallbackStillPairsEveryone() {
        let everyone: Set<Int> = [1, 2, 3, 4]
        let played = Dictionary(uniqueKeysWithValues: everyone.map { ($0, everyone.subtracting([$0])) })
        let pairs = TournamentPairing.pairWithoutRematches([1, 2, 3, 4], played: played)
        #expect(pairs.map { [$0.0, $0.1] } == [[1, 2], [3, 4]])
    }
}
