// APIServer/Services/ActivityEventThrottle.swift
//
// In-memory, per-user rate limiter for `user_activity_events` writes.  The
// activity chart only needs to know *whether* a user was active within a time
// bucket (the smallest bucket is one hour), so there's no value in recording
// more than one ping per user every few minutes.  This actor caps inserts at
// one per user per `window`, keeping the table small without changing the
// distinct-users-per-bucket counts the chart computes.
//
// The throttle is per-process: in a multi-process deployment each process
// keeps its own map, so a user pinning two processes can produce up to two
// rows per window.  That's harmless — aggregation counts *distinct users* per
// bucket, so duplicate rows collapse.

import Foundation
import Vapor

actor ActivityEventThrottle {
    /// One ping per user per this interval.  Five minutes sits well under the
    /// one-hour smallest chart bucket, so bucket membership is never missed.
    static let window: TimeInterval = 5 * 60

    private var lastRecorded: [UUID: Date] = [:]
    private let window: TimeInterval

    init(window: TimeInterval = ActivityEventThrottle.window) {
        self.window = window
    }

    /// Returns true (and arms the throttle) if `userID` is due for a new
    /// activity row; false if one was recorded within the window.
    func shouldRecord(userID: UUID, now: Date = Date()) -> Bool {
        if let last = lastRecorded[userID], now.timeIntervalSince(last) < window {
            return false
        }
        lastRecorded[userID] = now
        // Opportunistic eviction so the map can't grow without bound across a
        // long-running process: drop entries older than two windows (well past
        // any throttle relevance).
        if lastRecorded.count > 2048 {
            let cutoff = now.addingTimeInterval(-2 * window)
            lastRecorded = lastRecorded.filter { $0.value >= cutoff }
        }
        return true
    }
}

struct ActivityEventThrottleKey: StorageKey {
    typealias Value = ActivityEventThrottle
}

extension Application {
    /// Process-wide throttle gating `user_activity_events` inserts.
    var activityEventThrottle: ActivityEventThrottle {
        get {
            if let existing = storage[ActivityEventThrottleKey.self] { return existing }
            let created = ActivityEventThrottle()
            storage[ActivityEventThrottleKey.self] = created
            return created
        }
        set { storage[ActivityEventThrottleKey.self] = newValue }
    }
}
