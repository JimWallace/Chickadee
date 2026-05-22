// Tests/APITests/UserActivityMiddlewareTests.swift
//
// The activity-refresh debounce must stay strictly below the idle timeout, or
// SessionIdleTimeoutMiddleware logs out an actively-browsing user whose
// `last_seen_at` hasn't refreshed in time (regression: admin panel navigation
// signed users out after ~1 minute under a 1-minute test ceiling).

import Foundation
import Testing

@testable import APIServer

@Suite struct UserActivityMiddlewareTests {

    @Test func debounceStaysBelowShortTimeout() {
        // 1-minute test ceiling: debounce must be well under 60 s.
        let window = UserActivityMiddleware.debounceWindow(forIdleTimeoutSeconds: 60)
        #expect(window == 20)
        #expect(window < 60)
    }

    @Test func debounceCapsAtSixtyForLongTimeout() {
        // 30-minute production ceiling: keep the 60 s DB-write optimization.
        #expect(UserActivityMiddleware.debounceWindow(forIdleTimeoutSeconds: 30 * 60) == 60)
    }

    @Test func debounceStaysBelowTimeoutAcrossRange() {
        for timeout: TimeInterval in [30, 60, 90, 120, 300, 600, 1800] {
            let window = UserActivityMiddleware.debounceWindow(forIdleTimeoutSeconds: timeout)
            #expect(window < timeout, "debounce \(window) must be < timeout \(timeout)")
        }
    }

    @Test func disabledGateKeepsDefaultDebounce() {
        #expect(UserActivityMiddleware.debounceWindow(forIdleTimeoutSeconds: 0) == 60)
    }
}
