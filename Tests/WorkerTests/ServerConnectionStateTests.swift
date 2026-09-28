// Tests/WorkerTests/ServerConnectionStateTests.swift
//
// The runner's view of the server connection: a failed poll or heartbeat
// marks it lost, and a successful heartbeat marks it restored. The
// transitions are what emit `server_connection_lost` and
// `server_connection_restored`, the events docs/operational-diagnostics.md
// tells an operator to read. The mutation sweep of 2026-09-22 (#1574) deleted
// the lost-transition on the poll path and the restored-transition on the
// heartbeat path, and nothing failed for either.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(2))) struct ServerConnectionStateTests {

    private struct UnreachablePoller: JobPolling {
        func requestJob(activeJobs: Int) async throws(JobPollerError) -> Core.Job? {
            throw .transportError(URLError(.cannotConnectToHost))
        }
    }

    private struct NoJobPoller: JobPolling {
        func requestJob(activeJobs: Int) async throws(JobPollerError) -> Core.Job? { nil }
    }

    private struct HealthyReporter: Reporting {
        func report(_ report: WorkerExecutionReport) async throws(ReporterError) {}
        func heartbeat(_ payload: WorkerActivityPayload) async throws(ReporterError) {}
    }

    private static func daemon(poller: any JobPolling) -> WorkerDaemon {
        let fast = RunnerDaemonConfig.defaults
        return WorkerDaemon(
            poller: poller,
            reporter: HealthyReporter(),
            runner: UnsandboxedScriptRunner(),
            apiBaseURL: testURL("http://127.0.0.1:9"),
            workerID: "connection-state",
            workerSecret: "secret",
            maxConcurrentJobs: 1,
            testSetupCache: TestSetupCache(
                cacheRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("connection-state-\(UUID().uuidString)")),
            config: RunnerDaemonConfig(
                capabilityDiscoveryEnabled: false,
                testSetupCacheDir: nil,
                networkRetryEnabled: true,
                retryBaseDelayMs: 10,
                retryMaxDelayMs: 20,
                heartbeatRetryMaxAttempts: fast.heartbeatRetryMaxAttempts,
                resultUploadRetryMaxAttempts: fast.resultUploadRetryMaxAttempts,
                downloadRetryMaxAttempts: fast.downloadRetryMaxAttempts,
                minFreeDiskMB: 0,
                makeTimeoutSeconds: fast.makeTimeoutSeconds)
        )
    }

    @Test func anUnreachableServerOnPollMarksTheConnectionLost() async throws {
        let daemon = Self.daemon(poller: UnreachablePoller())
        let task = Task { try await daemon.run() }
        defer { task.cancel() }

        var lost = false
        for _ in 0..<200 where !lost {
            lost = await daemon.serverConnectionLost
            if !lost { try await Task.sleep(for: .milliseconds(25)) }
        }
        task.cancel()
        _ = await task.result
        #expect(lost, "a transport error on poll must mark the server connection lost")
    }

    @Test func aSuccessfulHeartbeatMarksALostConnectionRestored() async throws {
        let daemon = Self.daemon(poller: NoJobPoller())
        await daemon.recordConnectionLostIfNeeded(stage: .heartbeat, message: "down", retryInSeconds: nil)
        #expect(await daemon.serverConnectionLost)

        try await daemon.sendHeartbeat()
        #expect(await daemon.serverConnectionLost == false)
    }
}
