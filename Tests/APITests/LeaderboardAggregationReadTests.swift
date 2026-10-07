// Tests/APITests/LeaderboardAggregationReadTests.swift
//
// The two leaderboard pages read the aggregation axis by name, never by
// `default:` or by "none of the others" (#1745). The axis is exhaustive in
// Core so a fifth aggregation does not compile until answered; these two
// reads used to defeat that by routing an unknown case to the metric board.
// A source scan, because a compile-time guarantee that is the whole point
// cannot be observed by rendering a page.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct LeaderboardAggregationReadTests {

    private func source(_ relativePath: String) throws -> String {
        let url = repositoryRoot
        return try String(contentsOf: url.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Present mode names every aggregation in its switch and has no
    /// `default:` arm inside it.
    @Test func presentModeSwitchesOnEveryAggregationByName() throws {
        let text = try source("Sources/APIServer/Routes/Web/WebRoutes+LeaderboardPresent.swift")
        let start = try #require(text.range(of: "switch aggregation {"))
        let end = try #require(text.range(of: "let champion = ", range: start.upperBound..<text.endIndex))
        let block = text[start.lowerBound..<end.lowerBound]
        for aggregation in ActivityAggregation.allCases {
            #expect(block.contains("case .\(aggregation.rawValue):"), "missing case .\(aggregation.rawValue)")
        }
        #expect(!block.contains("default:"))
    }

    /// The leaderboard page defines the metric board flag as the leaderboard
    /// aggregation, not as the absence of the other three.
    @Test func theMetricBoardFlagNamesItsOwnAggregation() throws {
        let text = try source("Sources/APIServer/Routes/Web/WebRoutes+Leaderboard.swift")
        #expect(text.contains("let showsMetricBoard = activity.kind.aggregation == .leaderboard"))
        #expect(!text.contains("let showsMetricBoard = !showsStandings"))
    }
}
