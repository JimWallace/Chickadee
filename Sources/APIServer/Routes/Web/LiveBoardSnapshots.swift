// APIServer/Routes/Web/LiveBoardSnapshots.swift
//
// One `RosterSnapshot` per live board, shared by every refresh that reads
// the board at the same fingerprint (docs/live-board-cache.md). The first
// refresh after a change captures it; the refreshes that arrive while it is
// being captured wait for the same capture instead of starting their own, so
// 150 viewers polling one board cost one roster load per change, not one per
// poll.
//
// Per process and in memory: a blue-green cutover starts the new colour
// empty, and its first refresh of each board captures again.

import Foundation
import Vapor

actor LiveBoardSnapshots {
    private struct Key: Hashable {
        let testSetupID: String
        let groupID: UUID?
    }

    private struct Entry {
        let fingerprint: String
        let capture: Task<RosterSnapshot, any Error>
    }

    /// Boards kept at once. A course runs a few live activities at a time;
    /// past the cap the table starts again, which costs one capture each.
    static let capacity = 64

    private var entries: [Key: Entry] = [:]

    /// The snapshot of the board at `fingerprint`, captured by `capture`
    /// only when no refresh has captured it (or is capturing it) yet.
    func snapshot(
        testSetupID: String, groupID: UUID?, fingerprint: String,
        capture: @escaping @Sendable () async throws -> RosterSnapshot
    ) async throws -> RosterSnapshot {
        let key = Key(testSetupID: testSetupID, groupID: groupID)
        if let entry = entries[key], entry.fingerprint == fingerprint {
            return try await entry.capture.value
        }
        if entries.count >= Self.capacity, entries[key] == nil {
            entries.removeAll()
        }
        let task = Task { try await capture() }
        entries[key] = Entry(fingerprint: fingerprint, capture: task)
        do {
            return try await task.value
        } catch {
            // A failed capture is not kept: the next refresh tries again.
            if entries[key]?.fingerprint == fingerprint { entries[key] = nil }
            throw error
        }
    }

    /// The number of boards held, for the tests.
    var count: Int { entries.count }
}

struct LiveBoardSnapshotsKey: StorageKey {
    typealias Value = LiveBoardSnapshots
}

extension Application {
    var liveBoardSnapshots: LiveBoardSnapshots {
        lazyStored(LiveBoardSnapshotsKey.self) { LiveBoardSnapshots() }
    }
}
