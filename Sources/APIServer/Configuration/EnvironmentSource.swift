// APIServer/Configuration/EnvironmentSource.swift
//
// Where configuration reads the environment from.
//
// WHY THIS EXISTS, AND IT IS NOT ABOUT CONFIGURATION. Reading the process
// environment is not thread-safe against writing it: `setenv`/`unsetenv` rewrite
// glibc's `environ` array in place, and a concurrent `getenv` walking that array
// segfaults rather than returning a stale value. The whole process dies, at a
// different place each run, with nothing naming the cause.
//
// Nothing in production writes the environment, so production never had the
// problem. TESTS did, and unavoidably: a suite whose subject is "config is read
// correctly from the environment" had no way to exercise that except by calling
// `setenv`. Those writes then raced every reader in the process — including
// `Foundation.Process.run()`, which reads the parent environment on every
// subprocess spawn, of which the API suite performs dozens. It was the standing
// reason APITests needed `--no-parallel`.
//
// A lock could not fix it. The writers were few and already locked; the readers
// are everywhere, including inside Foundation where no lock can be added. So the
// fix is to remove the WRITERS: a test supplies an environment instead of
// mutating the process's, and the process environment is never written at all.
//
// The override is a `@TaskLocal`, which means it is visible to the code the test
// calls synchronously or via structured concurrency, and NOT to work that hops
// onto an unrelated executor. That limit is deliberate and safe in the direction
// that matters: a read that misses the override falls back to the real
// environment and the test sees a wrong VALUE — a visible, debuggable failure —
// rather than a silent race that kills the process.

import Foundation
import Vapor

/// The environment configuration reads from: the real process environment,
/// unless a test has supplied one for the current task.
enum EnvironmentSource {

    /// Set by `withTestEnvironment` (tests only). Nil in production, which is
    /// the entire production behaviour of this type.
    @TaskLocal static var override: [String: String]?

    /// One variable, from the override when there is one.
    static func get(_ key: String) -> String? {
        if let override { return override[key] }
        return Environment.get(key)
    }

    /// The whole environment, for the two places that build a CHILD process's
    /// environment out of the parent's.
    ///
    /// Those are the readers that made this more than a tidiness exercise:
    /// `Process.run()` reads the parent environment at spawn time whether or not
    /// we ask it to, so the only way a test can control what a child sees —
    /// without writing the real environment — is for our own code to hand the
    /// child an explicit environment built from this.
    static var all: [String: String] {
        override ?? ProcessInfo.processInfo.environment
    }
}
