// Tests/CoreTests/TournamentPairingTests.swift
//
// The pairing rules (docs/class-activities.md, "Tournaments") on five, eight
// and nine entrants: byes fall to the top seeds, every seed plays once per
// round, a round advances only when every slot has a winner, a bracket ends
// with one entrant standing, and a Swiss tournament plays ceil(log2 N)
// rounds without a rematch when one can be avoided.

import Foundation
import Testing

@testable import Core

@Suite struct TournamentPairingTests {

    /// Plays every open slot of `slots` with `winner` deciding, returning
    /// the completed slots.
    private func play(_ slots: [TournamentSlot], winner: (TournamentSlot) -> Int) -> [TournamentSlot] {
        slots.map { slot in
            var played = slot
            if played.winnerSeed == nil { played.winnerSeed = winner(slot) }
            return played
        }
    }

    private func higherSeedWins(_ slot: TournamentSlot) -> Int {
        min(slot.homeSeed, slot.awaySeed ?? slot.homeSeed)
    }

    /// Runs a whole tournament with `winner` deciding, returning every
    /// completed slot and the round count it took.
    private func run(
        schedule: TournamentSchedule, entrants: Int, winner: (TournamentSlot) -> Int
    ) -> (completed: [TournamentSlot], rounds: Int) {
        var completed = play(TournamentPairing.firstRound(schedule: schedule, entrantCount: entrants), winner: winner)
        var rounds = 1
        while let next = TournamentPairing.nextRound(schedule: schedule, entrantCount: entrants, completed: completed) {
            completed += play(next, winner: winner)
            rounds += 1
        }
        return (completed, rounds)
    }

    @Test func theBracketOrderKeepsTheTopSeedsApart() {
        #expect(TournamentPairing.bracketOrder(size: 1) == [1])
        #expect(TournamentPairing.bracketOrder(size: 2) == [1, 2])
        #expect(TournamentPairing.bracketOrder(size: 4) == [1, 4, 2, 3])
        #expect(TournamentPairing.bracketOrder(size: 8) == [1, 8, 4, 5, 2, 7, 3, 6])
    }

    @Test(arguments: [(2, 1), (3, 2), (5, 3), (8, 3), (9, 4), (16, 4), (17, 5)])
    func bothSchedulesPlayCeilLog2Rounds(entrants: Int, rounds: Int) {
        #expect(TournamentSchedule.bracket.roundCount(entrantCount: entrants) == rounds)
        #expect(TournamentSchedule.swiss.roundCount(entrantCount: entrants) == rounds)
        #expect(TournamentSchedule.bracket.roundCount(entrantCount: 1) == 0)
    }

    /// Five entrants fill an eight-slot bracket: seeds 1, 2 and 3 take the
    /// byes (already won) and 4 plays 5.
    @Test func fiveEntrantsGiveTheTopThreeSeedsByes() {
        let round = TournamentPairing.firstRound(schedule: .bracket, entrantCount: 5)
        #expect(round.count == 4)
        #expect(round.map(\.homeSeed) == [1, 4, 2, 3])
        #expect(round.map(\.awaySeed) == [nil, 5, nil, nil])
        #expect(round.map(\.winnerSeed) == [1, nil, 2, 3])
        #expect(round.map(\.position) == [0, 1, 2, 3])
        #expect(round.allSatisfy { $0.round == 1 })
    }

    /// Eight entrants have no byes; nine put eight of them on byes and play
    /// 8 against 9. Every seed appears exactly once in the first round.
    @Test(arguments: [5, 8, 9])
    func everySeedPlaysOnceInTheFirstRound(entrants: Int) {
        let round = TournamentPairing.firstRound(schedule: .bracket, entrantCount: entrants)
        let seeds = round.flatMap { [$0.homeSeed] + ($0.awaySeed.map { [$0] } ?? []) }
        #expect(seeds.sorted() == Array(1...entrants))
        let byes = round.filter(\.isBye).count
        #expect(byes == (entrants == 8 ? 0 : (entrants == 5 ? 3 : 7)))
        if entrants == 9 {
            #expect(round.contains { $0.homeSeed == 8 && $0.awaySeed == 9 })
        }
    }

    /// A bracket ends with the top seed when the higher seed always wins,
    /// after exactly ceil(log2 N) rounds, and the winner is only announced
    /// once nothing is left to play.
    @Test(arguments: [5, 8, 9])
    func aBracketEndsWithOneEntrantStanding(entrants: Int) {
        let (completed, rounds) = run(schedule: .bracket, entrants: entrants, winner: higherSeedWins)
        #expect(rounds == TournamentSchedule.bracket.roundCount(entrantCount: entrants))
        #expect(TournamentPairing.winner(schedule: .bracket, entrantCount: entrants, completed: completed) == 1)
        let final = completed.filter { $0.round == rounds }
        #expect(final.count == 1)
        #expect(final.first?.awaySeed != nil)
    }

    /// An upset propagates: the winner of a slot, not its seed, plays on.
    @Test func theWinnerOfASlotPlaysOnWhateverTheirSeed() {
        let (completed, _) = run(schedule: .bracket, entrants: 8) { slot in slot.awaySeed ?? slot.homeSeed }
        // Round 1 pairs (1,8) (4,5) (2,7) (3,6); the away seeds win, then
        // (8,5) and (7,6) → 5 and 6, then (5,6) → 6.
        #expect(TournamentPairing.winner(schedule: .bracket, entrantCount: 8, completed: completed) == 6)
        #expect(completed.filter { $0.round == 2 }.map { [$0.homeSeed, $0.awaySeed ?? 0] } == [[8, 5], [7, 6]])
    }

    /// No next round while any slot of the current one is open.
    @Test func aRoundAdvancesOnlyWhenEverySlotHasAWinner() {
        let first = TournamentPairing.firstRound(schedule: .bracket, entrantCount: 8)
        var partial = play(first, winner: higherSeedWins)
        partial[2].winnerSeed = nil
        #expect(TournamentPairing.nextRound(schedule: .bracket, entrantCount: 8, completed: partial) == nil)
        #expect(TournamentPairing.winner(schedule: .bracket, entrantCount: 8, completed: partial) == nil)
        #expect(TournamentPairing.nextRound(schedule: .bracket, entrantCount: 8, completed: []) == nil)
    }

    // MARK: - Swiss

    /// Five entrants: two matches and a bye for the lowest seed in round 1,
    /// and the bye rotates to someone who has not had one.
    @Test func swissGivesTheByeToTheLowestRankedWithoutOne() {
        let first = TournamentPairing.firstRound(schedule: .swiss, entrantCount: 5)
        #expect(first.count == 3)
        #expect(first.filter(\.isBye).map(\.homeSeed) == [5])
        #expect(first.filter { !$0.isBye }.map { [$0.homeSeed, $0.awaySeed ?? 0] } == [[1, 2], [3, 4]])
        let completed = play(first, winner: higherSeedWins)
        let second = TournamentPairing.nextRound(schedule: .swiss, entrantCount: 5, completed: completed)
        #expect(second?.count == 3)
        #expect(second?.filter(\.isBye).map(\.homeSeed) != [5])
    }

    /// Everyone plays every round, nobody meets the same entrant twice when
    /// that can be avoided, and the winner is the most points.
    @Test(arguments: [5, 8, 9])
    func swissPlaysEveryRoundWithoutARematch(entrants: Int) {
        let (completed, rounds) = run(schedule: .swiss, entrants: entrants, winner: higherSeedWins)
        #expect(rounds == TournamentSchedule.swiss.roundCount(entrantCount: entrants))
        for round in 1...rounds {
            let seeds = completed.filter { $0.round == round }
                .flatMap { [$0.homeSeed] + ($0.awaySeed.map { [$0] } ?? []) }
            #expect(seeds.sorted() == Array(1...entrants), "round \(round) of \(entrants)")
        }
        var pairs: Set<[Int]> = []
        for slot in completed where !slot.isBye {
            let pair = [slot.homeSeed, slot.awaySeed ?? 0].sorted()
            #expect(!pairs.contains(pair), "\(pair) met twice")
            pairs.insert(pair)
        }
        #expect(TournamentPairing.winner(schedule: .swiss, entrantCount: entrants, completed: completed) == 1)
        let standings = TournamentPairing.swissStandings(entrantCount: entrants, completed: completed)
        #expect(standings.first?.seed == 1)
        #expect(standings.first?.points == rounds)
    }

    @Test func schedulesRoundTripAndHaveChrome() throws {
        for schedule in TournamentSchedule.allCases {
            #expect(!schedule.displayName.isEmpty)
            #expect(!schedule.summary.isEmpty)
        }
        let decoded = try JSONDecoder().decode([TournamentSchedule].self, from: Data(#"["bracket","swiss"]"#.utf8))
        #expect(decoded == [.bracket, .swiss])
        let slot = TournamentSlot(round: 2, position: 1, homeSeed: 3, awaySeed: nil, winnerSeed: 3)
        #expect(try JSONDecoder().decode(TournamentSlot.self, from: JSONEncoder().encode(slot)) == slot)
    }
}
