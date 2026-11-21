// Tests/WorkerTests/Support/DaemonTestSupport.swift
//
// The shared stand-ins for a `WorkerDaemon` that never talks to a server: a
// poller that never has a job, a reporter that drops every call, and
// `makeTestDaemon`, which builds the daemon with a config that turns off
// capability discovery and the disk floor. Before this file, nine suites each
// carried their own copy of all three.

import ChickadeeTestSupport
import Core
import Foundation

@testable import chickadee_runner

/// A poller whose server never has a job.
struct NoJobPoller: JobPolling {
    func requestJob(activeJobs: Int) async throws(JobPollerError) -> Core.Job? { nil }
}

/// A reporter that accepts every report and heartbeat and records nothing.
struct NoopReporter: Reporting {
    func report(_ report: WorkerExecutionReport) async throws(ReporterError) {}
    func heartbeat(_ payload: WorkerActivityPayload) async throws(ReporterError) {}
}

/// A daemon pointed at port 9 (discard), where nothing listens.
///
/// The config is `RunnerDaemonConfig.defaults` with capability discovery off,
/// no test setup cache directory, and the given disk floor and retry delays.
/// `downloadRetryPolicy` and `testSetupCache` default to what `WorkerDaemon`
/// itself defaults them to.
func makeTestDaemon(
    workerID: String,
    poller: any JobPolling = NoJobPoller(),
    reporter: any Reporting = NoopReporter(),
    runner: any ScriptRunner = UnsandboxedScriptRunner(),
    maxConcurrentJobs: Int = 1,
    minFreeDiskMB: Int = 0,
    retryBaseDelayMs: Int = RunnerDaemonConfig.defaults.retryBaseDelayMs,
    retryMaxDelayMs: Int = RunnerDaemonConfig.defaults.retryMaxDelayMs,
    downloadRetryPolicy: RunnerRetryPolicy = .download(),
    testSetupCache: TestSetupCache = TestSetupCache()
) -> WorkerDaemon {
    let defaults = RunnerDaemonConfig.defaults
    return WorkerDaemon(
        poller: poller,
        reporter: reporter,
        runner: runner,
        apiBaseURL: testURL("http://127.0.0.1:9"),
        workerID: workerID,
        workerSecret: "secret",
        maxConcurrentJobs: maxConcurrentJobs,
        downloadRetryPolicy: downloadRetryPolicy,
        testSetupCache: testSetupCache,
        config: RunnerDaemonConfig(
            capabilityDiscoveryEnabled: false,
            testSetupCacheDir: nil,
            networkRetryEnabled: defaults.networkRetryEnabled,
            retryBaseDelayMs: retryBaseDelayMs,
            retryMaxDelayMs: retryMaxDelayMs,
            heartbeatRetryMaxAttempts: defaults.heartbeatRetryMaxAttempts,
            resultUploadRetryMaxAttempts: defaults.resultUploadRetryMaxAttempts,
            downloadRetryMaxAttempts: defaults.downloadRetryMaxAttempts,
            minFreeDiskMB: minFreeDiskMB,
            makeTimeoutSeconds: defaults.makeTimeoutSeconds))
}
