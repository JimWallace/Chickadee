// Tests/APITests/EnvTestLock.swift
//
// Shared lock for tests that manipulate process environment variables.
// `setenv` / `unsetenv` mutate process-global state, so two suites that
// both touch env vars (APIServerAppTests, DatabaseConfigurationTests)
// race against each other when Swift Testing runs them in parallel.
// `@Suite(.serialized)` only serializes within a suite, not across.
//
// Each env-touching test class acquires this lock in `init` and releases
// it in `deinit`, so for the duration of any one such test no other
// env-touching test (in any suite) can be running.

import Foundation

enum EnvTestLock {
    static let shared = NSLock()
}
