// APIServer/Routes/Web/RunnerStaleness.swift
//
// When a runner counts as offline.
//
// The threshold existed as three separate copies of the same magic number:
// two inline `Date.now() - lastActive > 5 * 60 * 1000` expressions in page
// scripts (the dashboard's worker table and the runner-detail header) and the
// prose in the docs. The two client copies could only run *during a poll*, so
// a freshly loaded dashboard showed no offline badges at all until the first
// tick — the badge was a property of having waited five seconds, not of the
// runner's state.
//
// It lives on the server now, evaluated once per render, so first paint and
// every background refresh give the same answer.

import Foundation

enum RunnerStaleness {
    /// A runner that has not checked in for this long is shown as offline.
    /// Runners poll far more often than this; the window is deliberately
    /// several poll intervals wide so one dropped request does not flap the
    /// badge.
    static let offlineAfter: TimeInterval = 5 * 60

    static func isOffline(lastActive: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastActive) > offlineAfter
    }
}
