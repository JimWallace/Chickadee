// Tests/WorkerTests/ReadInterruptionTests.swift
//
// The drain loop retries a `read` only when the call failed with EINTR. The
// mutation sweep of 2026-09-22 (#1574) weakened the `&&` in that rule to `||`
// and nothing failed, because no test can interrupt a drain thread with a
// signal. Under `||`, end of file with a stale EINTR left over from an earlier
// interrupted read counts as a retry, and the drain spins on a closed pipe.

import Foundation
import Testing

@testable import chickadee_runner

@Suite struct ReadInterruptionTests {

    @Test func anInterruptedFailedReadIsRetried() {
        #expect(readWasInterrupted(bytesRead: -1, errorNumber: EINTR))
    }

    @Test func endOfFileIsNotRetriedEvenWithAStaleInterrupt() {
        #expect(!readWasInterrupted(bytesRead: 0, errorNumber: EINTR))
    }

    @Test func anyOtherFailureIsNotRetried() {
        #expect(!readWasInterrupted(bytesRead: -1, errorNumber: EBADF))
        #expect(!readWasInterrupted(bytesRead: 0, errorNumber: 0))
    }
}
