// Tests/WorkerTests/Support/WorkerTestSkip.swift
//
// Worker-test-side helpers: the two `ConditionTrait`s only the worker needs
// (`.requiresSandbox`, `.requiresMake`), and `withMockURLProtocolLock`, which
// serializes access to `MockURLProtocol`'s process-global state. The
// interpreter traits and `.ciOnly` are shared by all three test targets and
// live in `ChickadeeTestSupport` (Tests/TestSupport/HostConditionTraits.swift),
// with `IssueRecorded` and `testURL`.

import ChickadeeTestSupport
import Foundation
import Testing

extension ConditionTrait {
    /// Skips, visibly, where `SandboxedScriptRunner` cannot sandbox: a Linux
    /// host that refuses `unshare` user and net namespaces, or a macOS host
    /// without `sandbox-exec`. Backed by the cached probe in
    /// ScriptRunnerTestSupport.swift.
    ///
    /// This replaces a `guard` that returned early whenever `GITHUB_ACTIONS`
    /// was set on Linux. The worker-tests lane has run `--privileged` since
    /// the mutation baseline probe measured `unshare` working there 20 of 20
    /// times, so that guard was skipping the sandbox boundary's only tests in
    /// the one place they were meant to run, and reporting them as passed.
    static let requiresSandbox: ConditionTrait = .enabled(
        "requires a working sandbox: unshare user/net namespaces on Linux, sandbox-exec on macOS"
    ) {
        await sandboxIsAvailable()
    }

    /// Skips, visibly, where `/usr/bin/make` is absent: the fixed path
    /// `RunnerDaemon` spawns for the pre-test build step, so the probe asks
    /// exactly what the daemon will ask.
    static let requiresMake: ConditionTrait = .enabled(
        if: FileManager.default.isExecutableFile(atPath: "/usr/bin/make"),
        "requires /usr/bin/make")
}

/// Serializes async test bodies that touch `MockURLProtocol`'s global
/// state.  `@Suite(.serialized)` is within-suite only; ReporterTests and
/// JobPollerTests are separate suites that share the same process-wide
/// stub queue and capture list.  Wrapping each touchy test body in
/// `withMockURLProtocolLock { ... }` forces them to run one at a time
/// across all suites.
func withMockURLProtocolLock<R: Sendable>(_ body: @Sendable () async throws -> R) async throws -> R {
    try await mockURLProtocolLock.run(body)
}

/// One permit: one `MockURLProtocol` body at a time, across every suite.
private let mockURLProtocolLock = AsyncPermits(limit: 1)

/// `@Test(.ciOnly)` resolves through `any TestTrait`, so the implicit-member
/// spelling needs the same `Trait where Self == ConditionTrait` extension the
/// built-in `.enabled(if:)` uses.
extension Trait where Self == ConditionTrait {
    static var requiresSandbox: Self { ConditionTrait.requiresSandbox }
    static var requiresMake: Self { ConditionTrait.requiresMake }
}
