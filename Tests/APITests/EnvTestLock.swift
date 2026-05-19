// Tests/APITests/EnvTestLock.swift
//
// Shared lock for tests that manipulate process environment variables.
// `setenv` / `unsetenv` mutate process-global state, so two suites that
// both touch env vars race against each other when Swift Testing runs
// them in parallel.  `@Suite(.serialized)` only serializes within a
// suite, not across.
//
// `withAsyncEnvLock { ... }` is the single serialization primitive —
// every test that mutates env vars and every helper that reads them
// during async setup must go through it.

import Foundation

/// Serializes async env-mutating test bodies across suites.
/// Only one `withAsyncEnvLock` closure can be running at a time process-wide.
func withAsyncEnvLock<R: Sendable>(_ body: @Sendable () async throws -> R) async rethrows -> R {
    try await AsyncEnvLock.shared.run(body)
}

/// Async helper to mutate process env vars for the duration of a test body
/// and restore them on exit (success or throw).  Uses the same actor-backed
/// lock as `withAsyncEnvLock` so env writers serialize against env readers
/// (e.g. `configureTestDatabase`'s call to `testDatabaseSettingsFromEnvironment`).
@discardableResult
func withTestEnvironment<R: Sendable>(
    _ overrides: [String: String?],
    perform body: @Sendable () async throws -> R
) async throws -> R {
    try await withAsyncEnvLock {
        var backup: [String: String?] = [:]
        for (key, value) in overrides {
            backup[key] = ProcessInfo.processInfo.environment[key]
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
        defer {
            for (key, value) in backup {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }
        return try await body()
    }
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
