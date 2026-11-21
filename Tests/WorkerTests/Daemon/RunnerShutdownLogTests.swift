// Tests/WorkerTests/Daemon/RunnerShutdownLogTests.swift
//
// The `runner_shutdown` event says whether the runner drained or was stopped.
// The mutation sweep of 2026-10-13 (#2535) swapped the two labels (`:93
// SwapTernary`) and nothing failed. An operator reading a runner's last line
// after `docker stop` would have seen `stopped` for a clean drain and
// `drained` for a cancellation, the opposite of what happened to the jobs.
//
// Protocol: docs/mutation-triage.md -- SURVIVED confirmed before, KILLED after.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(2))) struct RunnerShutdownLogTests {

    private static func daemon() -> WorkerDaemon {
        makeTestDaemon(workerID: "shutdown-log", retryBaseDelayMs: 20_000, retryMaxDelayMs: 20_000)
    }

    /// The `status` of every captured `runner_shutdown` line.
    private static func shutdownStatuses(in capture: RunnerLogCapture) -> [String] {
        capture.capturedLines.compactMap { line -> String? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                object["event"] as? String == "runner_shutdown"
            else { return nil }
            return object["status"] as? String
        }
    }

    /// Runs the daemon under a capture until `poll_cycle_start` is logged,
    /// so the run is under way when `stop` is applied, then waits for it.
    private static func runUntilStopped(
        _ stop: @Sendable (WorkerDaemon, Task<Void, any Error>) async -> Void
    ) async
        -> RunnerLogCapture
    {
        let capture = RunnerLogCapture()
        await RunnerLogCapture.$current.withValue(capture) {
            let daemon = Self.daemon()
            let run = Task { try await daemon.run() }
            for _ in 0..<400 where !capture.events.contains("poll_cycle_start") {
                try? await Task.sleep(for: .milliseconds(25))
            }
            await stop(daemon, run)
            _ = await run.result
        }
        return capture
    }

    @Test func aDrainedRunnerSaysDrained() async {
        let capture = await Self.runUntilStopped { daemon, _ in await daemon.drain() }
        #expect(Self.shutdownStatuses(in: capture) == ["drained"])
    }

    @Test func aCancelledRunnerSaysStopped() async {
        let capture = await Self.runUntilStopped { _, run in run.cancel() }
        #expect(Self.shutdownStatuses(in: capture) == ["stopped"])
    }
}
