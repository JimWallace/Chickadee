// Tests/APITests/Gamification/LeaderboardWindowBuildTests.swift
//
// A student's leaderboard builds only the rows its window shows, the
// viewer's own row and the row their card names (`leaderboardRowIndices`).
// The list it prints from those rows must be the list it printed when it
// built every row and windowed them afterwards.

import Testing

@testable import APIServer

@Suite struct LeaderboardWindowBuildTests {

    /// Competition ranks for `metrics`, best first, as `buildLeaderboard`
    /// computes them.
    private static func ranks(_ metrics: [Double]) -> [Int] {
        var ranks: [Int] = []
        for (index, metric) in metrics.enumerated() {
            ranks.append(index > 0 && metric == metrics[index - 1] ? ranks[index - 1] : index + 1)
        }
        return ranks
    }

    /// Boards of every shape the window treats differently: short and long,
    /// no ties, ties at the top, in the middle and at the end.
    private static let boards: [[Double]] = [
        [],
        [9],
        [9, 8],
        [5, 5, 5],
        Array(stride(from: 40.0, to: 0, by: -1)),
        [9, 9, 9, 9, 8, 7, 7, 6, 5, 4, 4, 4, 3, 2, 1, 1],
        [10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1],
        [3, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    ]

    /// Each list item as text: the gap label, or the index of the row.
    private static func describe(_ items: [LeaderboardWindowItem<Int>]) -> [String] {
        items.map { item in item.isGap ? "gap \(item.gapLabel)" : "row \(item.row.map(String.init) ?? "missing")" }
    }

    @Test(arguments: boards)
    func theWindowFromBuiltRowsIsTheWindowFromEveryRow(metrics: [Double]) {
        let ranks = Self.ranks(metrics)
        let rows = Array(metrics.indices)
        for viewerIndex in [nil] + metrics.indices.map(Optional.some) {
            let whole = leaderboardWindowItems(rows: rows, ranks: ranks, viewerIndex: viewerIndex, showAll: false)

            let slots = LeaderboardWindow.slots(ranks: ranks, viewerIndex: viewerIndex)
            let rival = viewerIndex.flatMap { LeaderboardNextPlace.targetIndex(metrics: metrics, viewerIndex: $0) }
            let built = leaderboardRowIndices(of: slots, plus: [viewerIndex, rival])
            let rowByIndex = Dictionary(uniqueKeysWithValues: built.map { ($0, rows[$0]) })
            let windowed = leaderboardWindowItems(slots: slots) { rowByIndex[$0] }

            #expect(Self.describe(windowed) == Self.describe(whole), "viewer \(String(describing: viewerIndex))")
            if let viewerIndex { #expect(built.contains(viewerIndex)) }
            if let rival { #expect(built.contains(rival)) }
        }
    }

    @Test func onlyTheWindowsRowsAreBuiltOnALongBoard() {
        let metrics = Array(stride(from: 200.0, to: 0, by: -1))
        let slots = LeaderboardWindow.slots(ranks: Self.ranks(metrics), viewerIndex: 100)
        let built = leaderboardRowIndices(of: slots, plus: [100, 99])
        // The top three places and two places either side of the viewer.
        #expect(built == [0, 1, 2, 98, 99, 100, 101, 102])
    }
}
