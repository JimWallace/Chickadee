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
    private let events = Mutex<[CapturedEvent]>([])
    private let capacity: Int

    init(capacity: Int = 2000) {
        self.capacity = max(1, capacity)
    }

    var bufferCapacity: Int { capacity }

    func record(_ event: CapturedEvent) {
        events.withLock { events in
            events.append(event)
            if events.count > capacity {
                events.removeFirst(events.count - capacity)
            }
        }
    }

    /// A point-in-time copy of the buffer, oldest first.
    func snapshot() -> [CapturedEvent] {
        events.withLock { $0 }
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
