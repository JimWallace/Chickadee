// Tests/APITests/Pages/ResultCountTilesTests.swift
//
// The result page's count tiles partition the tests (UI audit #3007,
// finding 2): a test skipped by a failed prerequisite counts once, as
// skipped, and a collection without outcomes keeps its own counts.

import Core
import Elementary
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct ResultCountTilesTests {

    private static let skipText = "Skipped: prerequisite 'test_build.py' did not pass"

    @Test func aDependencySkipCountsOnceAsSkipped() {
        let collection = wrMakeCollection(
            submissionID: "s",
            outcomes: [
                wrMakeOutcome(name: "a", status: .pass),
                wrMakeOutcome(name: "b", status: .fail),
                wrMakeOutcome(name: "c", status: .fail, shortResult: Self.skipText),
                wrMakeOutcome(name: "d", status: .error),
                wrMakeOutcome(name: "e", status: .timeout),
            ])
        let tiles = ResultCountTiles(collection: collection)
        #expect(tiles == ResultCountTiles(failed: 1, errors: 1, timedOut: 1, skipped: 1))
        #expect(collection.passCount + tiles.failed + tiles.errors + tiles.timedOut + tiles.skipped == 5)
    }

    @Test func aCollectionWithoutOutcomesKeepsItsOwnCounts() {
        let collection = TestOutcomeCollection(
            submissionID: "s", testSetupID: "t", attemptNumber: 1, buildStatus: .passed, compilerOutput: nil,
            outcomes: [], totalTests: 4, passCount: 1, failCount: 2, errorCount: 1, timeoutCount: 0,
            executionTimeMs: 0, warnings: [], runnerVersion: "r", timestamp: Date(timeIntervalSince1970: 0))
        #expect(
            ResultCountTiles(collection: collection) == ResultCountTiles(failed: 2, errors: 1, timedOut: 0, skipped: 0))
    }
}
