// Core/Tournament.swift
//
// The pure half of a tournament (docs/class-activities.md, "Tournaments"):
// which entrants meet in which round, and who has won. Nothing here touches a
// database or a job; the server snapshots entrants, stores the slots this
// produces, enqueues a match job per slot, and asks again when a round's
// results have all landed. Kept in Core so the schedules are testable on
// five, eight and nine entrants with no fixture at all.
//
// Two schedules. A single-elimination BRACKET seeds entrants into the next
// power of two, gives the top seeds the byes, and pairs winners in bracket
// order until one remains. A SWISS tournament plays ceil(log2 N) rounds in
// which entrants on equal points meet, avoiding a rematch where it can, and
// the entrant with the most points at the end wins. Neither has draws: the
// match script's exit code says whether the first entrant beat the one
// staged as the opponent, and anything else — a loss, an error, a timeout,
// a build failure — advances the opponent, so a broken submission can never
// stall a round.

import Foundation

/// How a tournament pairs its entrants.
public enum TournamentSchedule: String, Codable, CaseIterable, Sendable {
    /// Single elimination: lose once and you are out.
    case bracket
    /// Swiss: everyone plays every round, paired on equal points.
    case swiss

    /// Two-word chrome label.
    public var displayName: String {
        switch self {
        case .bracket: return "Single elimination"
        case .swiss: return "Swiss"
        }
    }

    /// One sentence for agents and fine print.
    public var summary: String {
        switch self {
        case .bracket:
            return "Single elimination: the top seeds take the byes, a loss is final, and the last "
                + "entrant standing wins."
        case .swiss:
            return "Swiss: everyone plays every round paired on equal points (ceil(log2 N) rounds), "
                + "and the most points at the end wins."
        }
    }

    /// How many rounds `entrantCount` entrants play. Both schedules need
    /// ceil(log2 N) rounds; one round for two entrants, none for fewer.
    public func roundCount(entrantCount: Int) -> Int {
        guard entrantCount >= 2 else { return 0 }
        var rounds = 0
        var size = 1
        while size < entrantCount {
            size *= 2
            rounds += 1
        }
        return rounds
    }
}

/// One entrant, frozen at the moment the tournament starts: who they are,
/// which submission plays for them, and their seed (1 = first to submit).
public struct TournamentEntrant: Codable, Equatable, Sendable {
    public let seed: Int
    public let userID: UUID
    public let submissionID: String

    public init(seed: Int, userID: UUID, submissionID: String) {
        self.seed = seed
        self.userID = userID
        self.submissionID = submissionID
    }
}

/// One slot of one round: the home seed plays the away seed, or has a bye
/// when `awaySeed` is nil. `winnerSeed` is nil while the match is out; a bye
/// is produced already won.
public struct TournamentSlot: Codable, Equatable, Sendable {
    public let round: Int
    /// Position within the round, from 0, in bracket order.
    public let position: Int
    public let homeSeed: Int
    public let awaySeed: Int?
    public var winnerSeed: Int?

    public init(round: Int, position: Int, homeSeed: Int, awaySeed: Int?, winnerSeed: Int? = nil) {
        self.round = round
        self.position = position
        self.homeSeed = homeSeed
        self.awaySeed = awaySeed
        self.winnerSeed = winnerSeed
    }

    /// A bye: the home seed advances with nobody to play.
    public var isBye: Bool { awaySeed == nil }
}

/// The pairing rules, one function per question the server asks.
public enum TournamentPairing {

    /// The first round's slots for `entrantCount` seeds (1...N).
    public static func firstRound(schedule: TournamentSchedule, entrantCount: Int) -> [TournamentSlot] {
        guard entrantCount >= 2 else { return [] }
        switch schedule {
        case .bracket:
            return bracketFirstRound(entrantCount: entrantCount)
        case .swiss:
            return swissRound(round: 1, entrantCount: entrantCount, completed: [])
        }
    }

    /// The next round's slots once every slot of the current round has a
    /// winner, or nil when the tournament is over. `completed` is every slot
    /// played so far, all with winners.
    public static func nextRound(
        schedule: TournamentSchedule, entrantCount: Int, completed: [TournamentSlot]
    ) -> [TournamentSlot]? {
        guard let last = completed.map(\.round).max(), completed.allSatisfy({ $0.winnerSeed != nil })
        else { return nil }
        switch schedule {
        case .bracket:
            let winners = completed.filter { $0.round == last }.sorted { $0.position < $1.position }
                .compactMap(\.winnerSeed)
            guard winners.count >= 2 else { return nil }
            return stride(from: 0, to: winners.count, by: 2).map { index in
                TournamentSlot(
                    round: last + 1, position: index / 2,
                    homeSeed: winners[index], awaySeed: index + 1 < winners.count ? winners[index + 1] : nil)
            }
        case .swiss:
            guard last < schedule.roundCount(entrantCount: entrantCount) else { return nil }
            return swissRound(round: last + 1, entrantCount: entrantCount, completed: completed)
        }
    }

    /// The winning seed once `nextRound` says the tournament is over: the
    /// last bracket winner, or the Swiss entrant with the most points (fewest
    /// byes, then the better seed, break a tie).
    public static func winner(
        schedule: TournamentSchedule, entrantCount: Int, completed: [TournamentSlot]
    ) -> Int? {
        guard nextRound(schedule: schedule, entrantCount: entrantCount, completed: completed) == nil,
            !completed.isEmpty
        else { return nil }
        switch schedule {
        case .bracket:
            let last = completed.map(\.round).max() ?? 0
            let finalists = completed.filter { $0.round == last }
            return finalists.count == 1 ? finalists[0].winnerSeed : nil
        case .swiss:
            return swissStandings(entrantCount: entrantCount, completed: completed).first?.seed
        }
    }

    /// One Swiss entrant's tally, in standings order.
    public struct SwissStanding: Equatable, Sendable {
        public let seed: Int
        public let points: Int
        public let byes: Int
    }

    /// Points per seed (a win or a bye is one point), best first.
    public static func swissStandings(entrantCount: Int, completed: [TournamentSlot]) -> [SwissStanding] {
        var points = [Int](repeating: 0, count: entrantCount + 1)
        var byes = [Int](repeating: 0, count: entrantCount + 1)
        for slot in completed {
            if slot.isBye {
                byes[slot.homeSeed] += 1
                points[slot.homeSeed] += 1
            } else if let winner = slot.winnerSeed {
                points[winner] += 1
            }
        }
        return (1...max(entrantCount, 1))
            .map { SwissStanding(seed: $0, points: points[$0], byes: byes[$0]) }
            .sorted { a, b in
                if a.points != b.points { return a.points > b.points }
                if a.byes != b.byes { return a.byes < b.byes }
                return a.seed < b.seed
            }
    }

    /// Pairs `order` (best first) so that no pair has met before, when such
    /// a pairing exists: a depth-first search that pairs the top unpaired
    /// entrant with the best-ranked candidate they have not played and
    /// backs out when that leaves someone below with only rematches. A
    /// greedy pass is wrong exactly there — on five entrants it pairs 1 with
    /// 4 in the last round and leaves 2 to replay 5. The search is bounded;
    /// past the budget, or when no rematch-free pairing exists, the greedy
    /// pairing with the fewest forced rematches at the top is used.
    static func pairWithoutRematches(_ order: [Int], played: [Int: Set<Int>]) -> [(Int, Int)] {
        var budget = 20_000
        func search(_ remaining: [Int]) -> [(Int, Int)]? {
            guard remaining.count >= 2 else { return [] }
            budget -= 1
            guard budget > 0 else { return nil }
            let home = remaining[0]
            for index in 1..<remaining.count where !(played[home]?.contains(remaining[index]) ?? false) {
                var rest = remaining
                rest.remove(at: index)
                rest.removeFirst()
                if let tail = search(rest) { return [(home, remaining[index])] + tail }
            }
            return nil
        }
        if let perfect = search(order) { return perfect }
        var unpaired = order
        var pairs: [(Int, Int)] = []
        while unpaired.count >= 2 {
            let home = unpaired.removeFirst()
            let index = unpaired.firstIndex { !(played[home]?.contains($0) ?? false) } ?? 0
            pairs.append((home, unpaired.remove(at: index)))
        }
        return pairs
    }

    // MARK: - Bracket

    /// Seeds laid into a bracket of `size` slots in the standard order — 1
    /// meets `size`, 2 meets `size - 1`, and so on — so the top seeds cannot
    /// meet before the final and the byes (seeds above N) fall to them.
    static func bracketOrder(size: Int) -> [Int] {
        var order = [1]
        var current = 1
        while current < size {
            current *= 2
            order = order.flatMap { [$0, current + 1 - $0] }
        }
        return order
    }

    private static func bracketFirstRound(entrantCount: Int) -> [TournamentSlot] {
        var size = 1
        while size < entrantCount { size *= 2 }
        let order = bracketOrder(size: size)
        return stride(from: 0, to: size, by: 2).map { index in
            let a = order[index]
            let b = order[index + 1]
            // A seed above N is a bye; the real entrant is always the home
            // side, and at most one side can be a bye (fewer than half the
            // slots are).
            let home = min(a, b)
            let away = max(a, b)
            let isBye = away > entrantCount
            return TournamentSlot(
                round: 1, position: index / 2, homeSeed: home, awaySeed: isBye ? nil : away,
                winnerSeed: isBye ? home : nil)
        }
    }

    // MARK: - Swiss

    private static func swissRound(round: Int, entrantCount: Int, completed: [TournamentSlot]) -> [TournamentSlot] {
        let standings = swissStandings(entrantCount: entrantCount, completed: completed)
        var played: [Int: Set<Int>] = [:]
        for slot in completed {
            guard let away = slot.awaySeed else { continue }
            played[slot.homeSeed, default: []].insert(away)
            played[away, default: []].insert(slot.homeSeed)
        }
        var order = standings.map(\.seed)
        var slots: [TournamentSlot] = []
        // An odd field gives the bye to the lowest-ranked entrant who has not
        // had one yet (everyone, if all have), scored as a win.
        var byeSeed: Int?
        if order.count % 2 == 1 {
            let candidate = standings.last { $0.byes == 0 } ?? standings[standings.count - 1]
            byeSeed = candidate.seed
            order.removeAll { $0 == candidate.seed }
        }
        for (home, away) in pairWithoutRematches(order, played: played) {
            slots.append(TournamentSlot(round: round, position: slots.count, homeSeed: home, awaySeed: away))
        }
        if let byeSeed {
            slots.append(
                TournamentSlot(
                    round: round, position: slots.count, homeSeed: byeSeed, awaySeed: nil, winnerSeed: byeSeed))
        }
        return slots
    }
}
