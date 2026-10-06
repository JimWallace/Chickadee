// APIServer/Utilities/AsyncCountingSemaphore.swift
//
// The one async semaphore in the server. It bounds concurrent personalization
// evaluations (#1156) and, with one permit, serializes SQLite job claims
// (`WorkerClaimQueue`).

/// Minimal counting semaphore for async contexts: `acquire` suspends (no
/// thread parked) once `width` slots are in use; `release` hands the slot to
/// the oldest waiter. Prefer `withPermit`, which always releases.
actor AsyncCountingSemaphore {
    private let width: Int
    private var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(width: Int) {
        self.width = max(1, width)
    }

    func acquire() async {
        if inUse < width {
            inUse += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        // Resumed by release(), which transfers the slot without
        // decrementing `inUse`.
    }

    func release() {
        if waiters.isEmpty {
            inUse -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Runs `body` while holding one slot, and releases the slot on every
    /// exit path, a thrown error included.
    nonisolated func withPermit<T>(_ body: () async throws -> T) async throws -> T {
        await acquire()
        do {
            let result = try await body()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }
}
