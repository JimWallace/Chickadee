// Tests/CoreTests/ZipProcessEnvironmentTests.swift
//
// The zip subprocess paths must never let Foundation read the global environ
// for them.
//
// WHY THIS IS A CRASH AND NOT A FLAKE YOU CAN RETRY. `Process.run()` with a
// nil `environment` inherits by reading environ itself. `setenv`/`unsetenv`
// can reallocate that array, so a spawn concurrent with an env-mutating test
// is an unsynchronized reader of freed memory. Sometimes the kernel notices
// and `run()` throws EFAULT — `runProcessWithEFAULTRetry` exists for exactly
// that, and absorbs it. Sometimes the read happens in user space instead, and
// then there is nothing to catch: the process dies.
//
// Observed 2026-08-09 on `api-tests` (PR #1313's run, unrelated diff):
//   *** Program crashed: Bad pointer dereference at 0x0000000000000210 ***
//   Thread 5: _ProcessInfo.environment.getter ← Process.run()
//             ← runProcessWithEFAULTRetry ← listZipEntries
//
// `withAsyncEnvLock` did not cover it. Its own header asks that "every test
// that mutates env vars and every helper that reads them" take the lock — a
// zip spawn is an *undeclared* reader, so it never did.

import Foundation
import Testing

@testable import Core

@Suite struct ZipProcessEnvironmentTests {

    /// The property the whole fix rests on: non-nil `environment` is what
    /// stops `run()` from doing the implicit read.
    @Test func makeZipProcessSuppliesAnEnvironment() {
        #expect(
            makeZipProcess().environment != nil,
            """
            makeZipProcess() left `environment` nil, so Process.run() will read the global \
            environ itself — the unsynchronized read that segfaults against a concurrent \
            setenv. This is the entire point of the factory.
            """)
    }

    /// The control for the test above: a bare `Process` really does start with
    /// a nil environment, so "non-nil" is a property the factory supplies
    /// rather than one Foundation was giving us anyway.
    @Test func aBareProcessHasNoEnvironmentUntilItIsGivenOne() {
        #expect(Process().environment == nil)
    }

    /// The snapshot is stable across calls, so two spawns cannot disagree
    /// about the environment and no second read happens per spawn.
    @Test func theSnapshotIsStableAcrossCalls() {
        #expect(makeZipProcess().environment == makeZipProcess().environment)
    }

    /// It is a real inherited environment, not an empty dictionary — the
    /// contents these spawns saw before the fix are preserved. `PATH` is set
    /// in every environment this runs in (CI container, dev shell); if that
    /// ever stops being true this wants relaxing, not deleting, because an
    /// accidental `[:]` would change what the child sees.
    @Test func theSnapshotCarriesTheInheritedEnvironment() throws {
        let environment = try #require(makeZipProcess().environment)
        guard ProcessInfo.processInfo.environment["PATH"] != nil else { return }
        #expect(environment["PATH"] != nil, "the snapshot dropped the inherited environment")
    }

    /// Drift guard. A new `/usr/bin/zip` or `/usr/bin/unzip` call site that
    /// constructs `Process()` directly silently opts back into the crash, and
    /// every existing test still passes — which is how this class of defect
    /// survives. Structural, not textual: it counts constructions against
    /// factory calls per file rather than pattern-matching prose about them.
    @Test func everyZipProcessSiteUsesTheFactory() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root

        // The files that spawn /usr/bin/zip or /usr/bin/unzip. Listed rather
        // than discovered because the rule is about those two executables, not
        // about `Process` in general — the worker spawns interpreters through
        // swift-subprocess and is not in scope.
        let zipSpawningFiles = [
            "Sources/Core/ZipArchiver.swift",
            "Sources/APIServer/Routes/Web/TestSetupZipHelpers.swift",
            "Sources/APIServer/Helpers/NotebookContentHelpers.swift",
        ]

        for relativePath in zipSpawningFiles {
            let source = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            // `makeZipProcess()` contains `Process()` as a substring, so count
            // constructions that are NOT preceded by an identifier character.
            let bareConstructions = source.ranges(of: "Process()").filter { range in
                guard range.lowerBound > source.startIndex else { return true }
                let preceding = source[source.index(before: range.lowerBound)]
                return !(preceding.isLetter || preceding.isNumber || preceding == "_")
            }
            #expect(
                bareConstructions.isEmpty,
                """
                \(relativePath) constructs Process() directly \(bareConstructions.count) time(s). \
                A zip/unzip spawn must use makeZipProcess(), or Process.run() reads the global \
                environ and can segfault against a concurrent setenv — uncatchably, so the \
                EFAULT retry does not save it. See docs/ci-flakiness.md Family 6.
                """)
            #expect(
                source.contains("makeZipProcess()"),
                "\(relativePath) no longer uses makeZipProcess() — did its zip spawn move?")
        }
    }
}
