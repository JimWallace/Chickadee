// APIServer/Routes/Web/LeaderboardWindow.swift
//
// The pure rules the leaderboard page applies to a ranked list, kept apart from
// the database code so each one can be tested with plain numbers
// (docs/class-activities.md).
//
//  - `LeaderboardWindow.slots` — which rows a student sees: the top three
//    places and the places around their own, with the rest folded into gap
//    rows.
//  - `LeaderboardStandingText` — the words for a rank: "14th", "Tied 14th".
//  - `LeaderboardNextPlace` — how far the viewer is from the next better row.

import Foundation

/// One entry of a windowed list: a row, by its index in the full list, or a run
/// of rows the window folded away.
enum LeaderboardWindowSlot: Equatable {
    case row(Int)
    /// `lowRank` and `highRank` are the ranks of the first and last hidden row.
    /// `isTrailing` is true when the run reaches the end of the list.
    case gap(count: Int, lowRank: Int, highRank: Int, isTrailing: Bool)
}

enum LeaderboardWindow {
    /// Rows with a rank up to this number are always shown.
    static let topRank = 3
    /// The places shown above and below the viewer's own place.
    static let reach = 2
    /// The rows shown when the viewer has no place on the board.
    static let unrankedViewerRows = 5

    /// The slots a student sees for `ranks`, which are competition ranks in
    /// best-first order (equal values are tied). `viewerIndex` is the index of
    /// the viewer's row, or nil when the viewer has none.
    ///
    /// The reach counts PLACES, not rows: a tie of four students is one place,
    /// so it never pushes the viewer's neighbours out of the window. A run of
    /// exactly one hidden row is shown instead of folded, since a line saying
    /// "1 more" takes the room of the row it hides.
    static func slots(ranks: [Int], viewerIndex: Int?) -> [LeaderboardWindowSlot] {
        guard !ranks.isEmpty else { return [] }
        let places = placeIndexes(ranks)
        var visible = ranks.indices.map { index -> Bool in
            if ranks[index] <= topRank { return true }
            guard let viewerIndex else { return index < unrankedViewerRows }
            return abs(places[index] - places[viewerIndex]) <= reach
        }

        var slots: [LeaderboardWindowSlot] = []
        var index = 0
        while index < ranks.count {
            if visible[index] {
                slots.append(.row(index))
                index += 1
                continue
            }
            var end = index
            while end < ranks.count, !visible[end] { end += 1 }
            if end - index == 1 {
                visible[index] = true
                slots.append(.row(index))
            } else {
                slots.append(
                    .gap(
                        count: end - index, lowRank: ranks[index], highRank: ranks[end - 1],
                        isTrailing: end == ranks.count))
            }
            index = end
        }
        return slots
    }

    /// The gap row's label: "14 more · 5–18", or "9 more below" at the end.
    static func gapLabel(count: Int, lowRank: Int, highRank: Int, isTrailing: Bool) -> String {
        if isTrailing { return "\(count) more below" }
        let span = lowRank == highRank ? "\(lowRank)" : "\(lowRank)–\(highRank)"
        return "\(count) more · \(span)"
    }

    /// The position of each row among the distinct ranks: 0 for the first
    /// place, 1 for the next one, whatever number of rows tied for each.
    private static func placeIndexes(_ ranks: [Int]) -> [Int] {
        var result: [Int] = []
        var place = -1
        var previous: Int?
        for rank in ranks {
            if rank != previous {
                place += 1
                previous = rank
            }
            result.append(place)
        }
        return result
    }
}

enum LeaderboardStandingText {
    /// "14th", "1st", "22nd", "13th".
    static func ordinal(_ number: Int) -> String {
        let lastTwo = number % 100
        let suffix: String
        if (11...13).contains(lastTwo) {
            suffix = "th"
        } else {
            switch number % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(number)\(suffix)"
    }

    /// "Tied 14th" or "14th".
    static func headline(rank: Int, isTied: Bool) -> String {
        isTied ? "Tied \(ordinal(rank))" : ordinal(rank)
    }

    /// The rank column's text: "14", or "14=" for a tie.
    static func rankText(rank: Int, isTied: Bool) -> String {
        isTied ? "\(rank)=" : "\(rank)"
    }

    /// "1", "2" or "3" for the three places that carry a disc colour; empty
    /// for every other rank.
    static func tier(rank: Int) -> String {
        (1...LeaderboardWindow.topRank).contains(rank) ? "\(rank)" : ""
    }

    /// A gap between two instants as a short phrase: "under a minute",
    /// "20 min", "3 h", "2 d".
    static func duration(seconds: TimeInterval) -> String {
        let value = abs(seconds)
        switch value {
        case ..<60: return "under a minute"
        case ..<3600: return "\(Int(value / 60)) min"
        case ..<86_400: return "\(Int(value / 3600)) h"
        default: return "\(Int(value / 86_400)) d"
        }
    }
}

enum LeaderboardNextPlace {
    /// The index of the row the viewer has to pass: the nearest row above
    /// `viewerIndex` whose metric is strictly better. Nil for the top place,
    /// and for a viewer tied at the top, since a tie has nobody to pass.
    /// `metrics` is best-first.
    static func targetIndex(metrics: [Double], viewerIndex: Int) -> Int? {
        guard metrics.indices.contains(viewerIndex) else { return nil }
        var index = viewerIndex - 1
        while index >= 0 {
            if metrics[index] > metrics[viewerIndex] { return index }
            index -= 1
        }
        return nil
    }

    /// The gap as the card prints it: "+0.004". A gap that would print as
    /// zero keeps two significant digits rather than promising nothing.
    static func deltaText(_ delta: Double) -> String {
        let text = formatLeaderboardMetric(delta)
        if text == "0", delta > 0 { return "+" + String(format: "%.2g", delta) }
        return "+" + text
    }
}
