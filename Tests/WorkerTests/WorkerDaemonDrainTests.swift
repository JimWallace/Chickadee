// Tests/WorkerTests/WorkerDaemonDrainTests.swift
//
// Cordon and drain: SIGTERM calls `WorkerDaemon.drain()`, and the runner then
// claims no new job, finishes and reports the jobs it is running, and stops.
// `docker stop` and every runner update send SIGTERM, so these tests are what
// keeps an update from cutting a student's job off and leaving it to the
// ten-minute reaper.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(2))) struct WorkerDaemonDrainTests {

    /// Answers every poll with `jobs` in order, then with no job.
    private actor CountingPoller: JobPolling {
        private var jobs: [Job]
        private(set) var requestCount = 0

        init(jobs: [Job] = []) {
            self.jobs = jobs
        }

        func requestJob(activeJobs: Int) async throws(JobPollerError) -> Job? {
            requestCount += 1
            return jobs.isEmpty ? nil : jobs.removeFirst()
        }
    }

    /// Holds the first report until `release()`, so a test can start a drain
    /// while a job is still being reported.
    private actor GatedReporter: Reporting {
        private(set) var reports: [TestOutcomeCollection] = []
        private(set) var isHoldingReport = false
        private var gate: CheckedContinuation<Void, Never>?

        func report(_ report: WorkerExecutionReport) async throws(ReporterError) {
            isHoldingReport = true
            await withCheckedContinuation { gate = $0 }
            reports.append(report.collection)
        }

        func heartbeat(_ payload: WorkerActivityPayload) async throws(ReporterError) {}

        func release() {
            gate?.resume()
            gate = nil
        }
    }

    private struct UnusedRunner: ScriptRunner {
        func run(script: URL, workDir: URL, timeLimitSeconds: Int, env: [String: String]) async -> ScriptOutput {
            ScriptOutput(exitCode: 0, stdout: "", stderr: "", executionTimeMs: 1, timedOut: false)
        }
    }

    /// The default configuration, with the first retry after `retryBaseDelayMs`.
    private func config(retryBaseDelayMs: Int) -> RunnerDaemonConfig {
        let defaults = RunnerDaemonConfig.defaults
        return RunnerDaemonConfig(
            capabilityDiscoveryEnabled: defaults.capabilityDiscoveryEnabled,
            testSetupCacheDir: defaults.testSetupCacheDir,
            networkRetryEnabled: defaults.networkRetryEnabled,
            retryBaseDelayMs: retryBaseDelayMs,
            retryMaxDelayMs: max(retryBaseDelayMs, defaults.retryMaxDelayMs),
            heartbeatRetryMaxAttempts: defaults.heartbeatRetryMaxAttempts,
            resultUploadRetryMaxAttempts: defaults.resultUploadRetryMaxAttempts,
            downloadRetryMaxAttempts: defaults.downloadRetryMaxAttempts,
            minFreeDiskMB: defaults.minFreeDiskMB,
            makeTimeoutSeconds: defaults.makeTimeoutSeconds)
    }

    /// A job whose downloads fail at once (nothing listens on port 1), so the
    /// runner reports a failure for it without running a script.
    private func makeJob() throws -> Job {
        let manifest = try JSONDecoder().decode(
            TestProperties.self,
            from: Data(
                #"""
                {"schemaVersion": 1, "gradingMode": "worker", "requiredFiles": [],
                 "testSuites": [{"tier": "public", "script": "test.sh"}],
                 "timeLimitSeconds": 1, "makefile": null}
                """#.utf8))
        return Job(
            submissionID: "sub_drain",
            testSetupID: "setup_drain",
            attemptNumber: 1,
            submissionURL: testURL("http://127.0.0.1:1/submission.zip"),
            testSetupURL: testURL("http://127.0.0.1:1/testsetup.zip"),
            manifest: manifest,
            submissionFilename: "submission.ipynb")
    }

    private func makeDaemon(
        poller: CountingPoller, reporter: GatedReporter, slots: Int, retryBaseDelayMs: Int
    )
        -> WorkerDaemon
    {
        WorkerDaemon(
            poller: poller,
            reporter: reporter,
            runner: UnusedRunner(),
            apiBaseURL: testURL("http://localhost:8080"),
            workerID: "worker-drain",
            workerSecret: "secret",
            maxConcurrentJobs: slots,
            downloadRetryPolicy: RunnerRetryPolicy(enabled: false, maxAttempts: 1, baseDelayMs: 10, maxDelayMs: 10),
            config: config(retryBaseDelayMs: retryBaseDelayMs))
    }

    private actor Flag {
        private(set) var isSet = false
        func set() { isSet = true }
    }

    /// Whether `run` returns within `seconds`. A run that does not is
    /// cancelled, so a broken drain fails the test rather than hanging it.
    private func finishes(_ run: Task<Void, Error>, within seconds: Double = 10) async -> Bool {
        let done = Flag()
        Task {
            _ = try? await run.value
            await done.set()
        }
        let finished = await waitUntil(seconds: seconds) { await done.isSet }
        if !finished { run.cancel() }
        return finished
    }

    private func waitUntil(seconds: Double = 10, _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    /// Idle slots sleep between polls, here for 20 seconds. The drain must not
    /// wait for that sleep, or an update of an idle runner would.
    @Test func anIdleRunnerStopsPromptlyAndPollsNoMore() async throws {
        let poller = CountingPoller()
        let daemon = makeDaemon(poller: poller, reporter: GatedReporter(), slots: 3, retryBaseDelayMs: 20_000)
        let run = Task { try await daemon.run() }
        #expect(await waitUntil { await poller.requestCount >= 3 }, "every slot polls once")

        let polledBeforeDrain = await poller.requestCount
        let start = Date()
        await daemon.drain()
        #expect(await finishes(run), "the runner did not stop after the drain")
        #expect(Date().timeIntervalSince(start) < 5, "the drain waited for an idle slot's sleep")
        #expect(await poller.requestCount == polledBeforeDrain)
        #expect(await daemon.isDraining)
    }

    /// A job that is running when the drain starts is finished and reported
    /// before the runner stops, and no slot claims another job.
    @Test func aRunningJobIsFinishedAndReportedBeforeTheRunnerStops() async throws {
        let poller = CountingPoller(jobs: [try makeJob()])
        let reporter = GatedReporter()
        let daemon = makeDaemon(poller: poller, reporter: reporter, slots: 2, retryBaseDelayMs: 50)
        let run = Task { try await daemon.run() }
        #expect(await waitUntil { await reporter.isHoldingReport }, "the job reaches its report")

        await daemon.drain()
        let pollsAtDrain = await poller.requestCount
        try await Task.sleep(for: .milliseconds(300))
        #expect(await reporter.reports.isEmpty, "the runner stopped before the job was reported")

        await reporter.release()
        #expect(await finishes(run), "the runner did not stop after the drain")
        let reports = await reporter.reports
        #expect(reports.count == 1)
        #expect(reports.first?.submissionID == "sub_drain")
        #expect(await poller.requestCount == pollsAtDrain, "a draining runner claimed another job")
    }

    @Test func aSecondDrainChangesNothing() async throws {
        let poller = CountingPoller()
        let daemon = makeDaemon(poller: poller, reporter: GatedReporter(), slots: 1, retryBaseDelayMs: 50)
        let run = Task { try await daemon.run() }
        #expect(await waitUntil { await poller.requestCount >= 1 })
        await daemon.drain()
        await daemon.drain()
        #expect(await finishes(run), "the runner did not stop after the drain")
        #expect(await daemon.isDraining)
    }
}
