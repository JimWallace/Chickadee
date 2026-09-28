// Tests/WorkerTests/TestSetupCacheEvictionRaceTests.swift
//
// `acquire` retries a scratch copy once when eviction removed the entry during
// the copy, and only then. The mutation sweep of 2026-09-22 (#1574) inverted
// the error filter and nothing failed, because no test can land an eviction in
// the middle of a copy. Inverted, the real race fails the job, and every other
// copy failure (a full disk, say) is retried for no benefit.

import Foundation
import Testing

@testable import chickadee_runner

@Suite struct TestSetupCacheEvictionRaceTests {

    @Test func aMissingSourceIsTheEvictionRace() {
        #expect(TestSetupCache.isEvictionRace(CocoaError(.fileReadNoSuchFile)))
    }

    @Test func anyOtherFailureIsNot() {
        #expect(!TestSetupCache.isEvictionRace(CocoaError(.fileWriteOutOfSpace)))
        #expect(!TestSetupCache.isEvictionRace(URLError(.cannotConnectToHost)))
    }
}
