// Tests/WorkerTests/JobWorkspaceLifecycleTests.swift
//
// The per-job workspace helpers in `Sources/Worker/JobWorkspace.swift`. The
// mutation sweep of 2026-10-13 (#2535) changed nine expressions there and
// nothing failed: the disk floor, the stage timings, the workdir removal and
// the two log events ops reads for capacity. Each was reached only through
// `process(_:)`, inside a running daemon, where no test looked at them.
//
// Protocol: docs/mutation-triage.md -- SURVIVED confirmed before, KILLED after.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(2))) struct JobWorkspaceLifecycleTests {

    private struct NoJobPoller: JobPolling {
        func requestJob(activeJobs: Int) async throws(JobPollerError) -> Job? { nil }
    }

    private struct HealthyReporter: Reporting {
        func report(_ report: WorkerExecutionReport) async throws(ReporterError) {}
        func heartbeat(_ payload: WorkerActivityPayload) async throws(ReporterError) {}
    }

    private static func daemon(minFreeDiskMB: Int) -> WorkerDaemon {
        let defaults = RunnerDaemonConfig.defaults
        return WorkerDaemon(
            poller: NoJobPoller(),
            reporter: HealthyReporter(),
            runner: UnsandboxedScriptRunner(),
            apiBaseURL: testURL("http://127.0.0.1:9"),
            workerID: "workspace-tests",
            workerSecret: "secret",
            maxConcurrentJobs: 1,
            config: RunnerDaemonConfig(
                capabilityDiscoveryEnabled: false,
                testSetupCacheDir: nil,
                networkRetryEnabled: defaults.networkRetryEnabled,
                retryBaseDelayMs: defaults.retryBaseDelayMs,
                retryMaxDelayMs: defaults.retryMaxDelayMs,
                heartbeatRetryMaxAttempts: defaults.heartbeatRetryMaxAttempts,
                resultUploadRetryMaxAttempts: defaults.resultUploadRetryMaxAttempts,
                downloadRetryMaxAttempts: defaults.downloadRetryMaxAttempts,
                minFreeDiskMB: minFreeDiskMB,
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
            submissionID: "sub_workspace",
            testSetupID: "setup_workspace",
            attemptNumber: 1,
            submissionURL: testURL("http://127.0.0.1:9/submission.zip"),
            testSetupURL: testURL("http://127.0.0.1:9/testsetup.zip"),
            manifest: manifest,
            submissionFilename: "submission.ipynb", language: nil)
    }

    private static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The decoded payload of every captured line whose event is `event`.
    private static func payloads(_ event: String, in capture: RunnerLogCapture) -> [[String: Any]] {
        capture.capturedLines.compactMap { line -> [String: Any]? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                object["event"] as? String == event
            else { return nil }
            return object
        }
    }

    // MARK: - The disk floor

    /// Survivor `:86 RelationalOperatorReplacement` (`minFreeDiskMB > 0` to
    /// `< 0`). The floor was never applied, so a runner below it staged the
    /// job anyway and failed partway through with ENOSPC, the failure the
    /// precheck exists to replace with a clear refusal.
    @Test func aJobBelowTheDiskFloorIsRefusedAndLogged() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let daemon = Self.daemon(minFreeDiskMB: 100)
        let job = try Self.makeJob()
        let capture = RunnerLogCapture()
        RunnerLogCapture.$current.withValue(capture) {
            #expect(throws: WorkerDaemonError.self) {
                try daemon.ensureSufficientDiskSpace(tempRoot: root, freeDiskMBAtStart: 50, job: job)
            }
        }
        let refusals = Self.payloads("insufficient_disk_space", in: capture)
        #expect(refusals.count == 1)
        #expect(refusals.first?["free_mb"] as? Int == 50)
        #expect(refusals.first?["required_mb"] as? Int == 100)
    }

    @Test func aJobAboveTheFloorOrWithNoFloorIsAccepted() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = try Self.makeJob()
        try Self.daemon(minFreeDiskMB: 100).ensureSufficientDiskSpace(tempRoot: root, freeDiskMBAtStart: 500, job: job)
        try Self.daemon(minFreeDiskMB: 100).ensureSufficientDiskSpace(tempRoot: root, freeDiskMBAtStart: nil, job: job)
        try Self.daemon(minFreeDiskMB: 0).ensureSufficientDiskSpace(tempRoot: root, freeDiskMBAtStart: 0, job: job)
    }

    // MARK: - Setup

    /// Survivor `:122 RemoveSideEffects`: the `workdir_setup` timing was no
    /// longer recorded, so the stage breakdown ops reads lost its first stage.
    @Test func setupCreatesTheWorkspaceAndRecordsBothStages() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var timings = JobStageTimings()
        let paths = try Self.daemon(minFreeDiskMB: 0)
            .setupJobWorkspace(tempRoot: root, job: try Self.makeJob(), stageTimings: &timings)

        #expect(paths.tempRoot == root)
        #expect(paths.workDir.lastPathComponent.hasPrefix("chickadee_sub_workspace_"))
        #expect(paths.submissionDir == paths.workDir.appendingPathComponent("submission", isDirectory: true))
        #expect(paths.submissionZip == paths.workDir.appendingPathComponent("submission.zip"))
        #expect(FileManager.default.fileExists(atPath: paths.submissionDir.path))
        #expect(timings.value(for: "workdir_setup") != nil)
        #expect(timings.value(for: "submission_dir_setup") != nil)
    }

    // MARK: - Teardown

    /// Survivors `:154` and `:157 RelationalOperatorReplacement` (`== nil` to
    /// `!= nil`), `:162` and `:163 RemoveSideEffects` (the workdir removal and
    /// the `cleanup` timing), `:171` and `:177 RemoveSideEffects` (the two
    /// log events) and `:216 RemoveSideEffects` (the `job_disk_usage` write).
    /// A job that failed before its readings were taken would have reported
    /// none, left its workdir on disk, and logged nothing ops could see.
    @Test func teardownOnTheErrorPathMeasuresRemovesAndLogs() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let daemon = Self.daemon(minFreeDiskMB: 0)
        let job = try Self.makeJob()
        var timings = JobStageTimings()
        let paths = try daemon.setupJobWorkspace(tempRoot: root, job: job, stageTimings: &timings)
        let payload = Data(repeating: 0x41, count: 4096)
        try payload.write(to: paths.submissionDir.appendingPathComponent("answer.txt"))
        var disk = JobDiskReadings(freeMBAtStart: 1000)

        let capture = RunnerLogCapture()
        RunnerLogCapture.$current.withValue(capture) {
            daemon.finalizeJobWorkspace(
                job: job, paths: paths, tempRoot: root, jobStartedAt: Date(),
                stageTimings: &timings, disk: &disk)
        }

        #expect(disk.workdirPeakBytes == payload.count, "the peak was measured before the removal")
        #expect(disk.freeMBAtEnd != nil)
        #expect(!FileManager.default.fileExists(atPath: paths.workDir.path), "the workdir stays on disk")
        #expect(timings.value(for: "cleanup") != nil)

        let stageTimings = Self.payloads("job_stage_timings", in: capture)
        #expect(stageTimings.count == 1)
        #expect(stageTimings.first?["cleanup_ms"] is Int)
        #expect(stageTimings.first?["submission_id"] as? String == "sub_workspace")

        let diskUsage = Self.payloads("job_disk_usage", in: capture)
        #expect(diskUsage.count == 1)
        #expect(diskUsage.first?["workdir_peak_bytes"] as? Int == payload.count)
        #expect(diskUsage.first?["free_disk_mb_at_start"] as? Int == 1000)
        #expect(diskUsage.first?["free_disk_mb_post_cleanup"] is Int)
    }

    /// The happy path measures right before the report, and the teardown must
    /// keep those readings rather than walk the directory again.
    @Test func teardownKeepsReadingsTheHappyPathAlreadyTook() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let daemon = Self.daemon(minFreeDiskMB: 0)
        let job = try Self.makeJob()
        var timings = JobStageTimings()
        let paths = try daemon.setupJobWorkspace(tempRoot: root, job: job, stageTimings: &timings)
        try Data(repeating: 0x41, count: 4096).write(to: paths.submissionDir.appendingPathComponent("answer.txt"))
        var disk = JobDiskReadings(freeMBAtStart: 1000, freeMBAtEnd: 999, workdirPeakBytes: 123_456)

        daemon.finalizeJobWorkspace(
            job: job, paths: paths, tempRoot: root, jobStartedAt: Date(), stageTimings: &timings, disk: &disk)

        #expect(disk.workdirPeakBytes == 123_456)
        #expect(disk.freeMBAtEnd == 999)
    }
}
