// Tests/WorkerTests/Support/WorkerTestSkip.swift
//
// Worker-test-side helpers: the shared `ConditionTrait`s that make a skip
// visible (`.ciOnly`, `.requiresMake`, `.requiresSandbox` and one per
// interpreter) and a
// `withMockURLProtocolLock` actor-backed serializer for `MockURLProtocol`'s
// process-global state. `IssueRecorded` and `testURL` come from
// `ChickadeeTestSupport`, shared with the other two test targets.
//
// A trait that two files need belongs here, not in a suite. The interpreter
// traits use `cachedToolIsAvailable`, so each tool is probed once per test
// process however many tests carry its trait.

import ChickadeeTestSupport
import Foundation
import Testing

extension ConditionTrait {
    /// Runs the test only in CI, where every grading interpreter must be
    /// present (`.github/docker/ci-image/Dockerfile`). Everywhere else the test
    /// reads as skipped, with this reason, instead of returning early in
    /// silence. `scripts/check-no-skipped-tests.sh` turns a skip on the CI
    /// image into a red job.
    static let ciOnly: ConditionTrait = .enabled(
        if: ProcessInfo.processInfo.environment["CI"] != nil,
        "runs only in CI, where every interpreter must be present")

    /// Skips, visibly, when `Rscript` does not answer `--version`. Backed by
    /// the cached probe in ScriptRunnerTestSupport.swift.
    static let requiresRscript: ConditionTrait = .enabled("requires Rscript on PATH") {
        await rscriptIsAvailable()
    }

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

    /// Skips, visibly, when `lua` does not answer `-v`. Lua has no
    /// `--version` flag, so the probe asks for `-v`.
    static let requiresLua: ConditionTrait = .enabled("requires lua on PATH") {
        await cachedToolIsAvailable("lua", arguments: ["-v"])
    }

    /// Skips, visibly, when `python3` does not answer `--version`.
    static let requiresPython3: ConditionTrait = .enabled("requires python3 on PATH") {
        await cachedToolIsAvailable("python3")
    }

    /// Skips, visibly, when `g++` does not answer `--version`.
    static let requiresGpp: ConditionTrait = .enabled("requires g++ on PATH") {
        await cachedToolIsAvailable("g++")
    }

    /// Skips, visibly, when `javac` does not answer `--version`. The probe is
    /// `javac`, not `java`: a JRE-only host is the real skew.
    static let requiresJavac: ConditionTrait = .enabled("requires javac on PATH") {
        await cachedToolIsAvailable("javac")
    }

    /// Skips, visibly, when `octave-cli` does not answer `--version`.
    static let requiresOctave: ConditionTrait = .enabled("requires octave-cli on PATH") {
        await cachedToolIsAvailable("octave-cli")
    }

    /// Skips, visibly, when `racket` does not answer `--version`.
    static let requiresRacket: ConditionTrait = .enabled("requires racket on PATH") {
        await cachedToolIsAvailable("racket")
    }
}

/// Serializes async test bodies that touch `MockURLProtocol`'s global
/// state.  `@Suite(.serialized)` is within-suite only; ReporterTests and
/// JobPollerTests are separate suites that share the same process-wide
/// stub queue and capture list.  Wrapping each touchy test body in
/// `withMockURLProtocolLock { ... }` forces them to run one at a time
/// across all suites.
func withMockURLProtocolLock<R: Sendable>(_ body: @Sendable () async throws -> R) async throws -> R {
    try await MockURLProtocolLock.shared.run(body)
}

private actor MockURLProtocolLock {
    static let shared = MockURLProtocolLock()
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

/// `@Test(.ciOnly)` resolves through `any TestTrait`, so the implicit-member
/// spelling needs the same `Trait where Self == ConditionTrait` extension the
/// built-in `.enabled(if:)` uses.
extension Trait where Self == ConditionTrait {
    static var ciOnly: Self { ConditionTrait.ciOnly }
    static var requiresRscript: Self { ConditionTrait.requiresRscript }
    static var requiresSandbox: Self { ConditionTrait.requiresSandbox }
    static var requiresMake: Self { ConditionTrait.requiresMake }
    static var requiresLua: Self { ConditionTrait.requiresLua }
    static var requiresPython3: Self { ConditionTrait.requiresPython3 }
    static var requiresGpp: Self { ConditionTrait.requiresGpp }
    static var requiresJavac: Self { ConditionTrait.requiresJavac }
    static var requiresOctave: Self { ConditionTrait.requiresOctave }
    static var requiresRacket: Self { ConditionTrait.requiresRacket }
}
