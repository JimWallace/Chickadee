// Tests/APITests/WedgeWatchdogArmingTests.swift
//
// Drift guard for the APITests half of the wedge watchdog.
//
// `WedgeWatchdog` only fires while a tracked scope is in flight, so the whole
// mechanism is worth exactly as much as its arming seam. Losing that seam is
// silent — every test still passes, and the next pool-saturation wedge is
// again a 20-minute `cancelled` job with nothing to diagnose from (issue
// #1233; the 2026-08-09 `api-tests` incident, Family 5 in
// docs/ci-flakiness.md). These tests fail instead.

import ChickadeeTestSupport
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct WedgeWatchdogArmingTests {

    /// `withApp` is APITests' universal test-body scope and therefore its
    /// arming seam. If the `WedgeWatchdog.track` wrapper is ever removed from
    /// it, the target silently loses the only stall guard that survives
    /// cooperative-pool saturation.
    @Test func withAppArmsTheWatchdog() async throws {
        let scopesBefore = WedgeWatchdog.activeTrackedScopes
        var scopesInside = 0
        let app = try await Application.make(.testing)
        try await withApp(app) { _ in
            scopesInside = WedgeWatchdog.activeTrackedScopes
        }
        #expect(scopesInside > scopesBefore)
    }

    /// Entering and leaving a tracked scope both count as activity, which is
    /// what makes a slow-but-progressing run (Family 5's actual shape) unable
    /// to trip the watchdog: the clock is reset by every test that starts or
    /// finishes, however long each one takes.
    @Test func completingATestResetsTheStallClock() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { _ in }
        #expect(WedgeWatchdog.secondsSinceLastActivity < 5)
    }

    /// The dump is the evidence path. It walks `/proc` on Linux and must
    /// degrade to a note rather than a crash where that does not exist.
    @Test func threadStateDumpDoesNotCrash() {
        WedgeWatchdog.dumpThreadStates(
            reason: "WedgeWatchdogArmingTests smoke test — not a real wedge")
    }
}
