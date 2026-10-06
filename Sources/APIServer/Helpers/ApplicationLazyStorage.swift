// APIServer/Helpers/ApplicationLazyStorage.swift
//
// The lazily-created process-wide singleton every store, cache and sweep
// keeps on `Application.storage`. Each accessor used to spell the same
// four-line get-or-create by hand; this is the one copy.

import Vapor

extension Application {
    /// The value stored under `key`, creating it with `make` on first access.
    ///
    /// Vapor locks a read of the whole `storage` struct and a write of the
    /// whole struct separately, so `storage[key] = value` is a read, a change
    /// and a write. Two first accesses to DIFFERENT keys at the same time could
    /// each write back a struct without the other's entry, and a sweep monitor
    /// lost that way outlived shutdown (#2298). The check and the store now run
    /// under the application lock. `make` runs outside it, so a `make` that
    /// itself calls `lazyStored` cannot deadlock; if two callers race, the
    /// first value stored wins and both return it.
    ///
    /// Direct `storage[key] = value` writes elsewhere are not under this lock.
    /// They run in `configure(_:)` and in test setup, before concurrent access.
    func lazyStored<Key: StorageKey>(_ key: Key.Type, make: () -> Key.Value) -> Key.Value {
        if let existing = sync.withLock({ storage[key] }) {
            return existing
        }
        let created = make()
        return sync.withLock {
            if let existing = storage[key] {
                return existing
            }
            storage[key] = created
            return created
        }
    }
}
