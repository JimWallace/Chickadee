// Tests/WorkerTests/TestSetupCacheMidCopyEvictionTests.swift
//
// A scratch copy whose source goes while `copyItem` walks it throws
// `.fileNoSuchFile` on Linux, not the `.fileReadNoSuchFile` of a source that
// is gone before the copy starts. Both are the eviction race, so both are
// retried. `TestSetupCacheEvictionRaceTests` covers the code that existed
// first and the failures that must not be retried.

import Foundation
import Testing

@testable import chickadee_runner

@Suite struct TestSetupCacheMidCopyEvictionTests {

    @Test func aSourceThatGoesDuringTheCopyIsTheEvictionRace() {
        #expect(TestSetupCache.isEvictionRace(CocoaError(.fileNoSuchFile)))
    }

    @Test func otherFileErrorsAreNot() {
        #expect(!TestSetupCache.isEvictionRace(CocoaError(.fileReadNoPermission)))
        #expect(!TestSetupCache.isEvictionRace(CocoaError(.fileWriteFileExists)))
    }
}
