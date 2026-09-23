// Tests/WorkerTests/RunnerLogEventTests.swift
//
// The runner's structured log events, read through `RunnerLogCapture`. The
// mutation sweep of 2026-09-22 (#1574) deleted or re-labelled fifteen log
// calls and nothing failed, because the lines went to stderr where no test
// could read them. Several are the events docs/operational-diagnostics.md
// tells an operator to watch (`poll_cycle_start` / `poll_cycle_end`,
// `heartbeat_retry_scheduled` vs `network_retry_scheduled`); the others are
// what an operator greps when asking why a submission graded the way it did
// (`runner_config_parse_failed`, `submission_guarantee_skipped`, the
// normalizer's per-file classification). Each test names the event it pins.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(3))) struct RunnerLogEventTests {

    // MARK: - Helpers

    /// Runs `body` with a capture bound and returns what it logged.
    private static func capturing(_ body: () async throws -> Void) async rethrows -> RunnerLogCapture {
        let capture = RunnerLogCapture()
        try await RunnerLogCapture.$current.withValue(capture) { try await body() }
        return capture
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

    private static let fastRetry = RunnerRetryPolicy(enabled: true, maxAttempts: 2, baseDelayMs: 10, maxDelayMs: 20)

    /// Port 9 (discard) has no listener, so every request is refused at once.
    private static let unreachable = testURL("http://127.0.0.1:9")

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

    private static func daemon(poller: any JobPolling = NoJobPoller()) -> WorkerDaemon {
        let defaults = RunnerDaemonConfig.defaults
        return WorkerDaemon(
            poller: poller,
            reporter: HealthyReporter(),
            runner: UnsandboxedScriptRunner(),
            apiBaseURL: unreachable,
            workerID: "log-events",
            workerSecret: "secret",
            maxConcurrentJobs: 1,
            downloadRetryPolicy: fastRetry,
            testSetupCache: TestSetupCache(
                cacheRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("log-events-\(UUID().uuidString)")),
            config: RunnerDaemonConfig(
                capabilityDiscoveryEnabled: false,
                testSetupCacheDir: nil,
                networkRetryEnabled: true,
                retryBaseDelayMs: 10,
                retryMaxDelayMs: 20,
                heartbeatRetryMaxAttempts: defaults.heartbeatRetryMaxAttempts,
                resultUploadRetryMaxAttempts: defaults.resultUploadRetryMaxAttempts,
                downloadRetryMaxAttempts: defaults.downloadRetryMaxAttempts,
                minFreeDiskMB: 0,
                makeTimeoutSeconds: defaults.makeTimeoutSeconds)
        )
    }

    /// Runs the daemon until `event` has been logged, then stops it.
    private static func runDaemon(_ daemon: WorkerDaemon, until event: String) async -> RunnerLogCapture {
        await capturing {
            let task = Task { try await daemon.run() }
            let capture = RunnerLogCapture.current
            for _ in 0..<200 where capture?.events.contains(event) != true {
                try? await Task.sleep(for: .milliseconds(25))
            }
            task.cancel()
            _ = await task.result
        }
    }

    // MARK: - The stderr write itself

    /// `RunnerStructuredLog.swift` — with no capture bound, a line reaches
    /// stderr. Run in a child process, since stderr is process-wide.
    @Test func withNoCaptureTheLineReachesStandardError() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardErrorContent]) {
            writeStructuredRunnerLog(event: "exit_test_probe", fields: ["slot": 1])
        }
        let stderr = try #require(String(bytes: result.standardErrorContent, encoding: .utf8))
        #expect(stderr.contains(#""event":"exit_test_probe""#))
    }

    /// A field JSON cannot hold still yields a line with the event name,
    /// rather than no line at all.
    @Test func aPayloadJSONCannotEncodeStillLogsItsEvent() async {
        let capture = await Self.capturing {
            writeStructuredRunnerLog(event: "unencodable_probe", fields: ["when": Date()])
        }
        #expect(capture.events == ["unencodable_probe"])
    }

    // MARK: - Configuration

    /// `runner_config_parse_failed` — a present but unparseable setting is
    /// reported, once per setting, for both the integer and boolean parsers.
    @Test func anUnparseableSettingIsReported() async throws {
        let capture = await Self.capturing {
            _ = RunnerDaemonConfig.loadFromEnvironment([
                "RUNNER_MIN_FREE_DISK_MB": "2GB",
                "RUNNER_CAPABILITY_DISCOVERY_ENABLED": "maybe",
            ])
        }
        let reported = Self.payloads("runner_config_parse_failed", in: capture)
        #expect(
            Set(reported.compactMap { $0["variable"] as? String }) == [
                "RUNNER_MIN_FREE_DISK_MB", "RUNNER_CAPABILITY_DISCOVERY_ENABLED",
            ])
        let disk = try #require(reported.first { $0["variable"] as? String == "RUNNER_MIN_FREE_DISK_MB" })
        #expect(disk["raw_value"] as? String == "2GB")
    }

    // MARK: - Submission handling

    /// `submission_guarantee_skipped` names the guarantee and the language.
    @Test func aSkippedGuaranteeIsLogged() async throws {
        let guarantee = try #require(SubmissionGuarantee.allCases.first)
        let capture = await Self.capturing {
            reportSkippedGuarantee(guarantee, language: .python, filename: "work.ipynb")
        }
        let logged = try #require(Self.payloads("submission_guarantee_skipped", in: capture).first)
        #expect(logged["guarantee"] as? String == guarantee.rawValue)
        #expect(logged["language"] as? String == "python")
        #expect(logged["file"] as? String == "work.ipynb")
    }

    /// The normalizer logs each file it refuses, detects and classifies.
    @Test func theNormalizerLogsEveryFileItHandles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-events-normalizer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let submission = root.appendingPathComponent("submission", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: submission, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        try "print('mine')\n".write(
            to: submission.appendingPathComponent("test_public.py"), atomically: true, encoding: .utf8)
        try "def f():\n    return 1\n".write(
            to: submission.appendingPathComponent("helper.py"), atomically: true, encoding: .utf8)
        let notebook = #"""
            {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","metadata":{},"source":["x = 1\n"]}]}
            """#
        try notebook.write(to: submission.appendingPathComponent("work.ipynb"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0, count: 64))
            .write(to: submission.appendingPathComponent("picture.png"))

        let manifest = try JSONDecoder().decode(
            TestProperties.self,
            from: Data(
                #"""
                {"schemaVersion": 1, "gradingMode": "worker", "requiredFiles": [],
                 "testSuites": [{"tier": "public", "script": "test_public.py"}],
                 "timeLimitSeconds": 10, "makefile": null}
                """#.utf8))

        let capture = try await Self.capturing {
            _ = try await SubmissionNormalizer().normalizePythonSubmission(
                manifest: manifest, submissionDirectory: submission, workspaceDirectory: workspace,
                submissionFilename: nil)
        }

        let refused = Self.payloads("submission_file_refused", in: capture)
        #expect(refused.map { $0["file"] as? String } == ["test_public.py"])

        let detected = Set(
            Self.payloads("submission_file_mime_detected", in: capture).compactMap { $0["file"] as? String })
        #expect(detected.isSuperset(of: ["helper.py", "work.ipynb", "picture.png"]))

        let classified = Dictionary(
            Self.payloads("submission_file_classified", in: capture).compactMap { payload -> (String, String)? in
                guard let file = payload["file"] as? String, let kind = payload["classification"] as? String
                else { return nil }
                return (file, kind)
            },
            uniquingKeysWith: { first, _ in first })
        #expect(classified["helper.py"] == "python_script")
        #expect(classified["work.ipynb"] == "jupyter_notebook")
        #expect(classified["picture.png"] == "unsupported")
    }

    // MARK: - The poll loop and the connection

    /// `poll_cycle_start` opens every poll cycle.
    @Test func everyPollCycleStartsWithAnEvent() async {
        let capture = await Self.runDaemon(Self.daemon(), until: "poll_cycle_start")
        #expect(capture.events.contains("poll_cycle_start"))
    }

    /// `poll_cycle_end` closes a cycle that failed to reach the server, with
    /// the status and the retry delay.
    @Test func aFailedPollEndsItsCycleWithAnEvent() async throws {
        let capture = await Self.runDaemon(Self.daemon(poller: UnreachablePoller()), until: "poll_cycle_end")
        let ended = try #require(Self.payloads("poll_cycle_end", in: capture).first)
        #expect(ended["status"] as? String == "transport_error")
        #expect(ended["retry_in_seconds"] != nil)
    }

    /// `heartbeat_retry_scheduled` — once the connection is already lost, a
    /// heartbeat with a retry scheduled says so, and a poll does not.
    @Test func onlyAHeartbeatLogsARetryOnceTheConnectionIsLost() async {
        let daemon = Self.daemon()
        let capture = await Self.capturing {
            await daemon.recordConnectionLostIfNeeded(stage: .poll, message: "down", retryInSeconds: 1)
            await daemon.recordConnectionLostIfNeeded(stage: .poll, message: "still down", retryInSeconds: 1)
            await daemon.recordConnectionLostIfNeeded(stage: .heartbeat, message: "still down", retryInSeconds: 2)
        }
        #expect(capture.events == ["server_connection_lost", "heartbeat_retry_scheduled"])
        // The event must come from the heartbeat call, not the second poll.
        let retry = Self.payloads("heartbeat_retry_scheduled", in: capture).first
        #expect(retry?["failure_stage"] as? String == "heartbeat")
        #expect(retry?["retry_in_seconds"] as? Int == 2)
    }

    /// A download retry names its stage: the submission and the test setup
    /// are told apart by the destination's filename.
    @Test(arguments: [("submission.zip", "download_submission"), ("setup.zip", "download_testsetup")])
    func aDownloadRetryNamesItsStage(filename: String, stage: String) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-events-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let daemon = Self.daemon()

        let capture = await Self.capturing {
            try? await daemon.download(
                url: Self.unreachable.appendingPathComponent("artifact"), to: dir.appendingPathComponent(filename))
        }
        let retries = Self.payloads("network_retry_scheduled", in: capture)
        #expect(!retries.isEmpty)
        #expect(retries.allSatisfy { $0["failure_stage"] as? String == stage })
    }

    /// The reporter's heartbeat retries are `heartbeat_retry_scheduled`, not
    /// the generic `network_retry_scheduled` a result upload logs.
    @Test func aHeartbeatRetryIsLoggedAsOne() async {
        let reporter = Reporter(
            apiBaseURL: Self.unreachable, workerID: "log-events", workerSecret: "secret",
            heartbeatRetryPolicy: Self.fastRetry, resultUploadRetryPolicy: Self.fastRetry)
        let payload = WorkerActivityPayload(
            workerID: "log-events", hostname: "host", runnerVersion: ChickadeeVersion.current,
            maxConcurrentJobs: 1, activeJobs: 0, profile: nil)
        let capture = await Self.capturing {
            try? await reporter.heartbeat(payload)
        }
        #expect(capture.events.contains("heartbeat_retry_scheduled"))
        #expect(!capture.events.contains("network_retry_scheduled"))
    }
}
