// Tests/TestSupport/AsyncPermits.swift
//
// A counting semaphore for async test code. With a limit of one it is a mutex
// that suspends instead of blocking a thread. The test targets used to carry
// three copies of this actor: the environment lock (APITests), the
// MockURLProtocol lock and the subprocess throttle (WorkerTests).

/// Runs at most `limit` bodies at once; the rest wait in arrival order.
public actor AsyncPermits {
    private let limit: Int
    private var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) {
        precondition(limit > 0, "a permit pool needs at least one permit")
        self.limit = limit
    }

    public func run<R: Sendable>(_ body: @Sendable () async throws -> R) async rethrows -> R {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if inUse < limit {
            inUse += 1
            return
        }
        // No free permit: park until a releaser hands one directly to us.
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if let next = waiters.first {
            // Hand the permit straight to the next waiter, so `inUse` stays
            // accurate and no newcomer can overtake a parked waiter.
            waiters.removeFirst()
            next.resume()
        } else {
            inUse -= 1
        }
    }
}
