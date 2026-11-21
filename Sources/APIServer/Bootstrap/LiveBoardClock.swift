// APIServer/Bootstrap/LiveBoardClock.swift
//
// The time a live board refresh reads. Its ETag and its roster snapshot both
// include a 30-second wall-clock bucket (`LiveBoardETag.bucket(at:)`), so two
// refreshes a moment apart can fall either side of a bucket edge and get
// different tags. Production reads the wall clock; a test pins the clock, so
// two refreshes of an unchanged board always share a bucket and its 304 is
// certain rather than likely.

import Foundation
import Vapor

/// The clock a live board refresh reads its time from.
struct LiveBoardClock: Sendable {
    let now: @Sendable () -> Date

    /// The wall clock.
    static let system = LiveBoardClock { Date() }

    /// A clock that always reads `date`.
    static func fixed(at date: Date) -> LiveBoardClock {
        LiveBoardClock { date }
    }
}

private struct LiveBoardClockKey: StorageKey {
    typealias Value = LiveBoardClock
}

extension Application {
    /// The clock of the live board refresh: the wall clock unless a test sets
    /// another before it sends requests.
    var liveBoardClock: LiveBoardClock {
        get { storage[LiveBoardClockKey.self] ?? .system }
        set { storage[LiveBoardClockKey.self] = newValue }
    }
}
