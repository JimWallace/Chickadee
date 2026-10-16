// APIServer/Services/AvatarIconCache.swift
//
// The rendered tab icons, by key (`AvatarIconKey`). The renderer is pure, so
// an entry never goes stale; the bound only stops a crawler that walks the key
// space from growing the cache without limit. When the cache is full, the
// entry used longest ago goes.

import Synchronization

final class AvatarIconCache: Sendable {
    private struct Entry {
        let svg: String
        var lastUse: UInt64
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var clock: UInt64 = 0
    }

    let capacity: Int
    private let state = Mutex(State())

    init(capacity: Int = 2_000) {
        self.capacity = capacity
    }

    var count: Int { state.withLock { $0.entries.count } }

    /// The cached icon for `key`, marked as just used, or nil.
    func svg(forKey key: String) -> String? {
        state.withLock { state in
            guard var entry = state.entries[key] else { return nil }
            state.clock += 1
            entry.lastUse = state.clock
            state.entries[key] = entry
            return entry.svg
        }
    }

    func insert(_ svg: String, forKey key: String) {
        state.withLock { state in
            state.clock += 1
            if state.entries[key] == nil, state.entries.count >= capacity,
                let oldest = state.entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key
            {
                state.entries[oldest] = nil
            }
            state.entries[key] = Entry(svg: svg, lastUse: state.clock)
        }
    }
}
