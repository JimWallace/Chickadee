// Tests/WorkerTests/Support/EnvTestLock.swift
//
// Process-wide serializer for WorkerTests bodies that mutate environment
// variables.  `setenv` / `unsetenv` touch process-global state, so two
// tests that both set the same variable race when Swift Testing runs them
// in parallel — `@Suite(.serialized)` only serializes within a suite, not
// the region during which a spawned daemon reads the variable back.
//
// Mirrors `withMockURLProtocolLock` in WorkerTestSkip.swift (same actor
// shape) and the `withAsyncEnvLock` primitive in
// `Tests/APITests/EnvTestLock.swift` — WorkerTests is a separate target, so
// it gets its own copy rather than importing the APITests one.

import Foundation

/// Serializes async test bodies that mutate process environment variables.
/// Only one `withEnvLock` closure runs at a time process-wide, so the
/// set → run → restore region of one env-mutating test never overlaps
/// another's.
func withEnvLock<R: Sendable>(_ body: @Sendable () async throws -> R) async throws -> R {
    try await EnvLock.shared.run(body)
}

private actor EnvLock {
    static let shared = EnvLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<R: Sendable>(_ body: @Sendable () async throws -> R) async throws -> R {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            locked = false
        }
    }
}
