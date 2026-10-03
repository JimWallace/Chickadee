// APIServer/BrightSpace/BrightSpaceGradeSyncSlot.swift
//
// One grade-sync sweep at a time in this process (#1923).
//
// A sweep reads every pending row and then pushes each one, and nothing claims
// a row. Two sweeps that overlap therefore push the same rows twice. Worse, a
// sweep that read a row before its grade changed can push the old grade after
// the other sweep pushed the new one, and then clear the pending flag, so the
// old grade stays in LEARN. The periodic sweep and a manual "Sync now" sweep
// could overlap like that. The leader lease cannot stop it inside one process,
// because both sweeps hold the lease as the same instance. So both take this
// slot first, and a sweep that finds the slot taken does not run.

import Synchronization
import Vapor

final class BrightSpaceGradeSyncSlot: Sendable {
    private let isTaken = Mutex(false)

    /// Runs `sweep` and returns its value, or returns nil without running it
    /// when another sweep holds the slot.
    func runIfFree<T: Sendable>(_ sweep: () async throws -> T) async rethrows -> T? {
        let claimed = isTaken.withLock { taken in
            guard !taken else { return false }
            taken = true
            return true
        }
        guard claimed else { return nil }
        defer { isTaken.withLock { $0 = false } }
        return try await sweep()
    }
}

struct BrightSpaceGradeSyncSlotKey: StorageKey {
    typealias Value = BrightSpaceGradeSyncSlot
}

extension Application {
    /// Set once at boot by `bootstrapAppServices`, before any sweep can race
    /// to create it: two slots would let two sweeps run at once again.
    var brightSpaceGradeSyncSlot: BrightSpaceGradeSyncSlot {
        get { lazyStored(BrightSpaceGradeSyncSlotKey.self) { BrightSpaceGradeSyncSlot() } }
        set { storage[BrightSpaceGradeSyncSlotKey.self] = newValue }
    }
}
