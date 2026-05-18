// Tests/APITests/EnvTestLock.swift
//
// Shared lock for tests that manipulate process environment variables.
// `setenv` / `unsetenv` mutate process-global state, so two suites that
// both touch env vars race against each other when Swift Testing runs
// them in parallel.  `@Suite(.serialized)` only serializes within a
// suite, not across.
//
// Sync path (`EnvTestLock.shared`): XCTest setUp/tearDown and Swift
// Testing's struct/class init are sync; they can use the NSLock
// directly.
//
// Async path (`EnvTestLock.withAsyncLock { ... }`): Swift 6 strict
// concurrency disallows `NSLock.lock()` from async functions because
// holding a sync lock across `await` is a deadlock hazard.  The actor-
// backed `withAsyncLock` provides equivalent serialization without
// holding any lock across suspension points — only one in-flight
// closure can execute at a time across all callers.

import Foundation

enum EnvTestLock {
    static let shared = NSLock()
}

/// Serializes async env-mutating test bodies across suites.
/// Only one `withAsyncLock` closure can be running at a time process-wide.
func withAsyncEnvLock<R: Sendable>(_ body: @Sendable () async throws -> R) async rethrows -> R {
    try await AsyncEnvLock.shared.run(body)
}

/// Backing actor for `withAsyncEnvLock`.  The single-entry actor
/// serializes its `run` calls; the `body` itself runs outside the
/// actor's isolation domain so caller-side async work is uninterrupted.
private actor AsyncEnvLock {
    static let shared = AsyncEnvLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<R: Sendable>(_ body: @Sendable () async throws -> R) async rethrows -> R {
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
