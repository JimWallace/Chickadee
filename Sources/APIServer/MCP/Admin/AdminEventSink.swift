// APIServer/MCP/Admin/AdminEventSink.swift
//
// The shared in-process "recent server events" source behind the admin
// diagnostic surface's query_logs tool (and any future event-driven admin
// query).  A bounded ring buffer fed by RingBufferLogHandler at log time; PII
// metadata keys are dropped before an event is stored, so the buffer is born
// clean.  Per-process and until-restart by design — for a single-instance
// deployment and live debugging that's the right tradeoff; it graduates to a
// retention-bounded table (same reader shape) if durability or multi-instance
// history is ever needed (docs/admin-mcp.md §6.2).

import Foundation
import Synchronization
import Vapor

/// One captured log/diagnostic event.  `metadata` is already PII-redacted.
struct CapturedEvent: Encodable, Sendable {
    let timestamp: Date
    /// Logger.Level raw value ("warning", "error", …).
    let level: String
    let label: String
    let message: String
    let metadata: [String: String]
}

/// Bounded ring buffer of recent events.  Thread-safe via a mutex because
/// `LogHandler.log` is synchronous and called from arbitrary threads, so an
/// actor (async-only) can't sit on that path.
final class AdminEventSink: Sendable {
    /// The stored events. Until it is full they are in arrival order; after
    /// that a new event overwrites the oldest, at `oldest`, so recording one
    /// never shifts the other `capacity - 1` while the lock is held.
    private struct Ring {
        var events: [CapturedEvent] = []
        var oldest = 0
    }

    private let ring = Mutex(Ring())
    private let capacity: Int

    init(capacity: Int = 2000) {
        self.capacity = max(1, capacity)
    }

    var bufferCapacity: Int { capacity }

    func record(_ event: CapturedEvent) {
        ring.withLock { ring in
            if ring.events.count < capacity {
                ring.events.append(event)
            } else {
                ring.events[ring.oldest] = event
                ring.oldest = (ring.oldest + 1) % capacity
            }
        }
    }

    /// A point-in-time copy of the buffer, oldest first.
    func snapshot() -> [CapturedEvent] {
        ring.withLock { ring in
            Array(ring.events[ring.oldest...]) + ring.events[..<ring.oldest]
        }
    }
}

// MARK: - Application storage

private struct AdminEventSinkKey: StorageKey {
    typealias Value = AdminEventSink
}

extension Application {
    /// The recent-events ring buffer, installed at startup by the logging
    /// bootstrap (`runAPIServer`).  Nil in contexts that don't bootstrap it
    /// (e.g. tests, which set it directly when exercising query_logs).
    var adminEventSink: AdminEventSink? {
        get { storage[AdminEventSinkKey.self] }
        set { storage[AdminEventSinkKey.self] = newValue }
    }
}
