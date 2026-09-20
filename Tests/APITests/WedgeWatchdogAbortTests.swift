// Tests/APITests/WedgeWatchdogAbortTests.swift
//
// The abort path of the wedge watchdog, observed from outside the process it
// ends.
//
// `WedgeWatchdogArmingTests` proves the arming seam and that the thread dump
// does not crash. Nothing could prove the path that matters — a tracked scope
// that stops reporting activity aborts the process with a thread table on
// stderr — because that path ends the process running the test. An exit test
// (`#expect(processExitsWith:)`) runs its body in a child of the test runner,
// so the abort is observed rather than suffered, and the child's stderr is
// the evidence.
//
// The monitor thread wakes every 15 s, so each test here takes about that
// long. That is the real loop, unmodified: a shorter interval would prove a
// seam CI never runs.

import ChickadeeTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(2))) struct WedgeWatchdogAbortTests {

    /// A tracked scope that reports no activity past the stall limit ends the
    /// process with SIGABRT, and the thread dump names the limit that fired.
    @Test func aSilentTrackedScopeAbortsWithAThreadDump() async throws {
        let result = try await #require(
            processExitsWith: .signal(SIGABRT), observing: [\.standardErrorContent]
        ) {
            // `stallLimitSeconds` reads the variable once, on first use, so it
            // is set before this child's first tracked scope.
            setenv("CHICKADEE_WORKERTESTS_STALL_SECONDS", "1", 1)
            try await WedgeWatchdog.track {
                // Longer than the limit and than the monitor's wake interval.
                // The abort ends this sleep.
                try await Task.sleep(for: .seconds(120))
            }
        }
        let stderr = try #require(String(bytes: result.standardErrorContent, encoding: .utf8))
        #expect(stderr.contains("==== WedgeWatchdog thread dump (issue #1233) ===="))
        #expect(stderr.contains("no test activity for"))
        #expect(stderr.contains("Stall limit was 1s"))
        #expect(stderr.contains("wchan="), "the dump carries the per-thread table on Linux")
    }

    /// `CHICKADEE_WORKERTESTS_STALL_SECONDS=0` disables the abort: the same
    /// silent scope, longer than the monitor's wake interval, ends normally.
    @Test func aZeroStallLimitDisablesTheAbort() async {
        await #expect(processExitsWith: .success) {
            setenv("CHICKADEE_WORKERTESTS_STALL_SECONDS", "0", 1)
            try await WedgeWatchdog.track {
                try await Task.sleep(for: .seconds(20))
            }
        }
    }
}
