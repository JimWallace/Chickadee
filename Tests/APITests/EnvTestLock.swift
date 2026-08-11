// Tests/APITests/EnvTestLock.swift
//
// How tests supply environment variables — by SUPPLYING one (`withTestEnvironment`,
// below), not by writing the process's. `withAsyncEnvLock` survives for the few
// tests that still need a REAL process variable, one a child must inherit
// through the OS rather than through our own code.
//
// Historical note, because the lock's own doc argues for an approach this file
// has since moved past: serializing writers against readers cannot be made to
// work here. `setenv` rewrites glibc's `environ` in place and the readers
// include `Foundation.Process.run()`, which reads the parent environment on
// every subprocess spawn — inside Foundation, where no lock of ours reaches.
//
// Original note follows.
//
// Shared lock for tests that manipulate process environment variables.
// `setenv` / `unsetenv` mutate process-global state, so two suites that
// both touch env vars race against each other when Swift Testing runs
// them in parallel.  `@Suite(.serialized)` only serializes within a
// suite, not across.
//
// `withAsyncEnvLock { ... }` is the single serialization primitive —
// every test that mutates env vars and every helper that reads them
// during async setup must go through it.  The lock is reentrant on the
// same task (tracked via a TaskLocal) so wrapping `configureTestDatabase`
// in the lock doesn't deadlock callers that are already inside a
// `withTestEnvironment` block.

import Foundation

@testable import APIServer

/// Set inside the locked region so nested calls on the same task can
/// reenter without parking.
enum AsyncEnvLockHolding {
    @TaskLocal static var isHeld: Bool = false
}

/// Serializes async env-mutating test bodies across suites.
/// Only one `withAsyncEnvLock` closure can be running at a time process-wide.
/// Reentrant within the same task: nested calls run the body inline.
///
/// READERS MUST TAKE IT TOO, not just writers. This is the part that is easy to
/// get wrong and it has been got wrong: `setenv`/`unsetenv` rewrite glibc's
/// `environ` array in place, so a concurrent `getenv` walking it does not read a
/// stale value — it segfaults. The whole test process dies, at a different test
/// each run, with no failing test name attached. It reads as a flake.
///
/// `configureTestDatabase` locked its database-settings read and then read
/// `TEST_LOG_LEVEL` thirty lines lower, outside the block — on every one of the
/// suite's ~1,100 test Applications, making it the most frequent env reader in
/// the process. Every writer was correct; that one reader was enough to make
/// `swift test --parallel` crash reliably and earn a standing `--no-parallel`
/// workaround. Both reads now share one locked region.
///
/// A source-scanning guard for this was tried and abandoned: a lexical scan
/// cannot tell an unlocked read from a helper whose only caller holds the lock
/// (`testDatabaseSettingsFromEnvironment` and `OIDCTests.EnvironmentOverride`
/// are both the latter), so it produced more exemptions than findings. The
/// invariant lives here instead, where someone adding an env read will be
/// looking.
func withAsyncEnvLock<R: Sendable>(_ body: @Sendable () async throws -> R) async throws -> R {
    if AsyncEnvLockHolding.isHeld {
        return try await body()
    }
    return try await AsyncEnvLock.shared.run {
        try await AsyncEnvLockHolding.$isHeld.withValue(true) {
            try await body()
        }
    }
}

/// Runs `body` with `overrides` applied on top of the environment, WITHOUT
/// writing the process environment.
///
/// This used to `setenv`/`unsetenv` and restore afterwards, serialized against
/// other writers by `withAsyncEnvLock`. The lock could never make that safe:
/// `setenv` rewrites glibc's `environ` array in place, and every concurrent
/// reader — including `Foundation.Process.run()`, which reads the parent
/// environment on every subprocess spawn — walks that array without any lock we
/// can reach. A racing reader segfaults rather than reading a stale value, so
/// the whole test process died at a different test each run. That was the
/// standing reason APITests needed `--no-parallel`.
///
/// The overrides now ride a `@TaskLocal` that `EnvironmentSource` consults, so
/// there is no writer to race with and no lock to take. Call sites are
/// unchanged.
///
/// WHAT IT DOES NOT REACH, stated because the failure mode is quiet-but-visible
/// rather than silent: a task-local is not seen by work that hops onto an
/// unrelated executor, so configuration read from inside a request handler on a
/// NIO event loop would see the real environment. That surfaces as a test
/// reading a wrong VALUE — an ordinary assertion failure someone can debug —
/// not as a crash. Every current caller reads config synchronously or through
/// structured concurrency, which is inside the binding.
///
/// A `nil` override means "unset for this body", matching `unsetenv`.
@discardableResult
func withTestEnvironment<R: Sendable>(
    _ overrides: [String: String?],
    perform body: @Sendable () async throws -> R
) async throws -> R {
    var environment = EnvironmentSource.override ?? ProcessInfo.processInfo.environment
    for (key, value) in overrides {
        if let value {
            environment[key] = value
        } else {
            environment.removeValue(forKey: key)
        }
    }
    return try await EnvironmentSource.$override.withValue(environment) {
        try await body()
    }
}

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
