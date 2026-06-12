// Tests/WorkerTests/Support/SubprocessThrottle.swift
//
// Process-wide ceiling on the number of *real* subprocesses WorkerTests
// launches at once.
//
// WorkerTests is unusual among the suites: it spawns real `/bin/sh` and
// `python3` processes, and Swift Testing runs tests in parallel within the
// process by default (the `swift test --filter WorkerTests` CI invocation is
// non-`--parallel`, but that flag only governs XCTest's *cross-process*
// scheduling — in-process Swift Testing parallelism is unaffected).  Under the
// cold-cache nightly — every test in the target firing at once on a 2-core
// runner — the resulting fork/posix_spawn storm transiently fails.  It
// surfaces as the `-1` "never launched" exit sentinel (see
// `runScriptRobustly`) or a starved daemon `Task` (see WorkerDaemonTests'
// `waitUntil`).  Both prior mitigations reacted to one symptom each; this is
// the shared root-cause lever: bound the number of concurrent launches so the
// storm can't form, while keeping enough parallelism that the suite stays fast.
//
// Same actor shape as `withEnvLock` / `withMockURLProtocolLock`, generalized
// from a binary lock to `limit` permits.  Only the launch is throttled, not
// the subprocess's lifetime — long-lived helpers (e.g. `LocalHTTPTestServer`)
// acquire a slot for `run() + port read`, then release while the server keeps
// serving.

import Foundation

/// Runs `body` while holding one of a small, fixed number of subprocess-launch
/// permits.  Wrap the *launch* of any real `Process` (or any `ScriptRunner.run`
/// that forks one) so concurrent forks stay bounded across every suite.
func withSubprocessSlot<R: Sendable>(_ body: @Sendable () async throws -> R) async rethrows -> R {
    try await SubprocessThrottle.shared.run(body)
}

private actor SubprocessThrottle {
    // Deliberately a small fixed constant rather than scaled to core count:
    // the failure mode is resource exhaustion under load, and the 2-core CI
    // runner is exactly where it bites, so a low floor is the safe choice.  A
    // cheap `/bin/sh` fork is sub-millisecond, so four in flight is ample
    // throughput while staying far below the storm threshold.
    static let shared = SubprocessThrottle(limit: 4)

    private let limit: Int
    private var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func run<R: Sendable>(_ body: @Sendable () async throws -> R) async rethrows -> R {
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
            // Transfer our permit straight to the next waiter: neither
            // decrement nor re-increment, so `inUse` stays accurate.
            waiters.removeFirst()
            next.resume()
        } else {
            inUse -= 1
        }
    }
}
