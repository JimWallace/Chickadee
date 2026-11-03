// Tests/WorkerTests/OffActorWorkTests.swift
//
// The workspace file-system work runs off the `WorkerDaemon` actor (#2779).
// Before the fix, `process(_:)` ran each synchronous helper on the actor's
// executor. With `--max-jobs N`, one slot's large teardown held the actor,
// and the heartbeats and reports of every other slot waited on it.

import ChickadeeTestSupport
import Core
import Dispatch
import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(2))) struct OffActorWorkTests {

    private struct NoJobPoller: JobPolling {
        func requestJob(activeJobs: Int) async throws(JobPollerError) -> Job? { nil }
    }

    private struct HealthyReporter: Reporting {
        func report(_ report: WorkerExecutionReport) async throws(ReporterError) {}
        func heartbeat(_ payload: WorkerActivityPayload) async throws(ReporterError) {}
    }

    private static func daemon() -> WorkerDaemon {
        let defaults = RunnerDaemonConfig.defaults
        return WorkerDaemon(
            poller: NoJobPoller(),
            reporter: HealthyReporter(),
            runner: UnsandboxedScriptRunner(),
            apiBaseURL: testURL("http://127.0.0.1:9"),
            workerID: "off-actor-tests",
            workerSecret: "secret",
            maxConcurrentJobs: 2,
            config: RunnerDaemonConfig(
                capabilityDiscoveryEnabled: false,
                testSetupCacheDir: nil,
                networkRetryEnabled: defaults.networkRetryEnabled,
                retryBaseDelayMs: defaults.retryBaseDelayMs,
                retryMaxDelayMs: defaults.retryMaxDelayMs,
                heartbeatRetryMaxAttempts: defaults.heartbeatRetryMaxAttempts,
                resultUploadRetryMaxAttempts: defaults.resultUploadRetryMaxAttempts,
                downloadRetryMaxAttempts: defaults.downloadRetryMaxAttempts,
                minFreeDiskMB: 0,
                makeTimeoutSeconds: defaults.makeTimeoutSeconds))
    }

    private static func makeJob() throws -> Job {
        let manifest = try JSONDecoder().decode(
            TestProperties.self,
            from: Data(
                #"""
                {"schemaVersion": 1, "gradingMode": "worker", "requiredFiles": [],
                 "testSuites": [{"tier": "public", "script": "test.sh"}],
                 "timeLimitSeconds": 1, "makefile": null}
                """#.utf8))
        return Job(
            submissionID: "sub_off_actor",
            testSetupID: "setup_off_actor",
            attemptNumber: 1,
            submissionURL: testURL("http://127.0.0.1:9/submission.zip"),
            testSetupURL: testURL("http://127.0.0.1:9/testsetup.zip"),
            manifest: manifest,
            submissionFilename: "submission.ipynb", language: nil)
    }

    private static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-off-actor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Calls `runOffActor` from the daemon's own isolation, as `process(_:)`
    /// does. The work blocks until `release` is signalled, or for at most
    /// ten seconds, and returns whether the release came.
    private static func blockOnDaemon(
        _ daemon: isolated WorkerDaemon,
        started: DispatchSemaphore,
        release: DispatchSemaphore
    ) async -> Bool {
        await runOffActor {
            started.signal()
            return release.wait(timeout: .now() + 10) == .success
        }
    }

    // MARK: - The actor stays free

    /// The issue's acceptance test, at the level of the primitive every
    /// workspace step goes through. One "slot" starts a blocking piece of
    /// file-system work from the daemon actor. A second slot then sends a
    /// heartbeat, which needs the actor. If the work ran on the actor, the
    /// heartbeat would wait for it, the release would not come in time, and
    /// the work would report a timeout.
    @Test func blockingWorkStartedFromTheActorDoesNotBlockAHeartbeat() async throws {
        let daemon = Self.daemon()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        let slot = Task { await Self.blockOnDaemon(daemon, started: started, release: release) }

        // Wait for the work to start, without blocking a cooperative thread
        // the work could need.
        let didStart = await runOffActor { started.wait(timeout: .now() + 10) == .success }
        try #require(didStart, "the off-actor work did not start")

        try await daemon.sendHeartbeat()
        _ = await daemon.activeJobs
        release.signal()

        #expect(await slot.value, "the heartbeat waited for the work, so the work ran on the actor")
    }

    // MARK: - The wrappers keep the behaviour

    @Test func setupOffActorCreatesTheWorkspaceAndRecordsBothStages() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var timings = JobStageTimings()
        let paths = try await Self.daemon()
            .setupJobWorkspaceOffActor(tempRoot: root, job: try Self.makeJob(), stageTimings: &timings)

        #expect(FileManager.default.fileExists(atPath: paths.submissionDir.path))
        #expect(timings.value(for: "workdir_setup") != nil)
        #expect(timings.value(for: "submission_dir_setup") != nil)
    }

    @Test func diskSampleOffActorFillsBothReadings() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let daemon = Self.daemon()
        var timings = JobStageTimings()
        let paths = try await daemon.setupJobWorkspaceOffActor(
            tempRoot: root, job: try Self.makeJob(), stageTimings: &timings)
        let payload = Data(repeating: 0x41, count: 4096)
        try payload.write(to: paths.submissionDir.appendingPathComponent("answer.txt"))
        var disk = JobDiskReadings(freeMBAtStart: 1000)

        await daemon.sampleEndOfExecutionDiskOffActor(workDir: paths.workDir, tempRoot: root, disk: &disk)

        #expect(disk.workdirPeakBytes == payload.count)
        #expect(disk.freeMBAtEnd != nil)
        #expect(disk.freeMBAtStart == 1000)
    }

    /// The teardown writes its readings and its `cleanup` timing back to the
    /// caller, removes the workdir, and still logs through the task-local
    /// capture: the hop changes the executor, not the task.
    @Test func finalizeOffActorRemovesTheWorkdirAndWritesBack() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let daemon = Self.daemon()
        let job = try Self.makeJob()
        var timings = JobStageTimings()
        let paths = try await daemon.setupJobWorkspaceOffActor(tempRoot: root, job: job, stageTimings: &timings)
        let payload = Data(repeating: 0x41, count: 4096)
        try payload.write(to: paths.submissionDir.appendingPathComponent("answer.txt"))
        var disk = JobDiskReadings(freeMBAtStart: 1000)

        let capture = RunnerLogCapture()
        await RunnerLogCapture.$current.withValue(capture) {
            await daemon.finalizeJobWorkspaceOffActor(
                job: job, paths: paths, tempRoot: root, jobStartedAt: Date(),
                stageTimings: &timings, disk: &disk)
        }

        #expect(!FileManager.default.fileExists(atPath: paths.workDir.path))
        #expect(disk.workdirPeakBytes == payload.count)
        #expect(disk.freeMBAtEnd != nil)
        #expect(timings.value(for: "cleanup") != nil)
        #expect(capture.capturedLines.contains { $0.contains("\"job_disk_usage\"") })
        #expect(capture.capturedLines.contains { $0.contains("\"job_stage_timings\"") })
    }

    @Test func removeWorkspaceItemOffActorRemovesTheTree() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = root.appendingPathComponent("test_setup", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tree.appendingPathComponent("nested", isDirectory: true), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: tree.appendingPathComponent("nested/file.txt"))

        await Self.daemon().removeWorkspaceItemOffActor(at: tree, label: "test_setup_dir", job: try Self.makeJob())

        #expect(!FileManager.default.fileExists(atPath: tree.path))
    }
}
