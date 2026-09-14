// APIServer/Helpers/ApplicationLazyStorage.swift
//
// The lazily-created process-wide singleton every store, cache and sweep
// keeps on `Application.storage`. Each accessor used to spell the same
// four-line get-or-create by hand; this is the one copy.

import Vapor

extension Application {
    /// The value stored under `key`, creating it with `make` on first
    /// access. Not synchronised: a transient boot-time race creates the
    /// value twice and keeps the second, which every caller here tolerates
    /// (the values are caches and idempotent sweeps).
    func lazyStored<Key: StorageKey>(_ key: Key.Type, make: () -> Key.Value) -> Key.Value {
        if let existing = storage[key] {
            return existing
        }
        let created = make()
        storage[key] = created
        return created
    }
}
