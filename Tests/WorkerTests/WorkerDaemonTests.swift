import XCTest
@testable import chickadee_runner
import Core
import Foundation
#if os(Linux)
import Glibc
#endif

final class WorkerDaemonTests: XCTestCase {
    private let fastRetryPolicy = RunnerRetryPolicy(
        enabled: true,
        maxAttempts: 2,
        baseDelayMs: 10,
        maxDelayMs: 20
    )

    private let generousRetryPolicy = RunnerRetryPolicy(
        enabled: true,
        maxAttempts: 5,
        baseDelayMs: 10,
        maxDelayMs: 20
    )

    private final class StaticFileServer {
        let process: Process
        let port: Int
        private let stdout: Pipe

        init(directory: URL) throws {
            process = Process()
            stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "python3",
                "-c",
                #"""
import http.server
import socketserver
import sys

directory = sys.argv[1]

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=directory, **kwargs)

    def log_message(self, format, *args):
        pass

with socketserver.TCPServer(("127.0.0.1", 0), Handler) as httpd:
    print(httpd.server_address[1], flush=True)
    httpd.serve_forever()
"""#,
                directory.path
            ]

            try process.run()

            let data = stdout.fileHandleForReading.availableData
            guard
                let line = String(data: data, encoding: .utf8)?
                    .split(separator: "\n")
                    .first,
                let port = Int(line)
            else {
                process.terminate()
                throw XCTSkip("python3 is unavailable for local static file serving")
            }

            self.port = port
        }

        func stop() {
            guard process.isRunning else { return }
            process.terminate()
            for _ in 0..<20 where process.isRunning {
                Thread.sleep(forTimeInterval: 0.05)
            }

            if process.isRunning {
#if os(Linux)
                _ = Glibc.kill(process.processIdentifier, SIGKILL)
#else
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
#endif
            }

            process.waitUntilExit()
            stdout.fileHandleForReading.closeFile()
        }
    }

    private actor MockPoller: JobPolling {
        private var jobs: [Job?]
        private(set) var requestCount = 0

        init(jobs: [Job?]) {
            self.jobs = jobs
        }

        func requestJob(activeJobs: Int) async throws(JobPollerError) -> Job? {
            requestCount += 1
            if jobs.isEmpty {
                return nil
            }
            return jobs.removeFirst()
        }

        func observedRequestCount() -> Int {
            requestCount
        }
    }

    private actor FlakyPoller: JobPolling {
        enum FailureMode {
            case http500
            case duplicateWorkerID
        }

        private var failuresRemaining: Int
        private let failureMode: FailureMode
        private(set) var requestCount = 0

        init(failuresRemaining: Int, failureMode: FailureMode) {
            self.failuresRemaining = failuresRemaining
            self.failureMode = failureMode
        }

        func requestJob(activeJobs: Int) async throws(JobPollerError) -> Job? {
            requestCount += 1
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                switch failureMode {
                case .http500:
                    throw .httpError(500, "temporary server failure")
                case .duplicateWorkerID:
                    throw .duplicateWorkerID("workerID already in use")
                }
            }
            return nil
        }

        func observedRequestCount() -> Int {
            requestCount
        }
    }

    private actor MockReporter: Reporting {
        private var collections: [TestOutcomeCollection] = []
        private var heartbeatCount = 0

        func report(_ collection: TestOutcomeCollection) async throws(ReporterError) {
            collections.append(collection)
        }

        func heartbeat(_ payload: WorkerActivityPayload) async throws(ReporterError) {
            heartbeatCount += 1
        }

        func snapshot() -> [TestOutcomeCollection] {
            collections
        }

        func observedHeartbeatCount() -> Int {
            heartbeatCount
        }
    }

    private actor FlakyReporter: Reporting {
        private var failuresRemaining: Int
        private var attempts = 0
        private var collections: [TestOutcomeCollection] = []
        private var heartbeatFailuresRemaining = 0
        private var heartbeatAttempts = 0

        init(failuresRemaining: Int) {
            self.failuresRemaining = failuresRemaining
        }

        init(failuresRemaining: Int, heartbeatFailuresRemaining: Int) {
            self.failuresRemaining = failuresRemaining
            self.heartbeatFailuresRemaining = heartbeatFailuresRemaining
        }

        func report(_ collection: TestOutcomeCollection) async throws(ReporterError) {
            attempts += 1
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                throw ReporterError.httpError(500, "temporary failure")
            }
            collections.append(collection)
        }

        func heartbeat(_ payload: WorkerActivityPayload) async throws(ReporterError) {
            heartbeatAttempts += 1
            if heartbeatFailuresRemaining > 0 {
                heartbeatFailuresRemaining -= 1
                throw ReporterError.transportError(URLError(.cannotConnectToHost))
            }
        }

        func observedAttempts() -> Int {
            attempts
        }

        func snapshot() -> [TestOutcomeCollection] {
            collections
        }

        func observedHeartbeatAttempts() -> Int {
            heartbeatAttempts
        }
    }

    private final class FlakyHTTPServer {
        let process: Process
        let port: Int
        private let stdout: Pipe

        init(failuresBeforeSuccess: Int, responseBody: String = "payload") throws {
            process = Process()
            stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "python3",
                "-c",
                #"""
import http.server
import socketserver
import sys

remaining = int(sys.argv[1])
body = sys.argv[2].encode("utf-8")

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        global remaining
        if remaining > 0:
            remaining -= 1
            self.send_response(503)
            self.end_headers()
            self.wfile.write(b"unavailable")
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass

with socketserver.TCPServer(("127.0.0.1", 0), Handler) as httpd:
    print(httpd.server_address[1], flush=True)
    httpd.serve_forever()
"""#,
                String(failuresBeforeSuccess),
                responseBody
            ]

            try process.run()

            let data = stdout.fileHandleForReading.availableData
            guard
                let line = String(data: data, encoding: .utf8)?
                    .split(separator: "\n")
                    .first,
                let port = Int(line)
            else {
                process.terminate()
                throw XCTSkip("python3 is unavailable for local flaky HTTP serving")
            }

            self.port = port
        }

        func stop() {
            guard process.isRunning else { return }
            process.terminate()
            for _ in 0..<20 where process.isRunning {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
#if os(Linux)
                _ = Glibc.kill(process.processIdentifier, SIGKILL)
#else
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
#endif
            }
            process.waitUntilExit()
            stdout.fileHandleForReading.closeFile()
        }
    }

    private actor MockRunner: ScriptRunner {
        private(set) var invocationCount = 0
        let output: ScriptOutput

        init(output: ScriptOutput) {
            self.output = output
        }

        func run(script: URL, workDir: URL, timeLimitSeconds: Int) async -> ScriptOutput {
            invocationCount += 1
            return output
        }

        func observedInvocationCount() -> Int {
            invocationCount
        }
    }

    private func makeManifest() throws -> TestProperties {
        try JSONDecoder().decode(TestProperties.self, from: Data(#"""
        {
          "schemaVersion": 1,
          "gradingMode": "worker",
          "requiredFiles": [],
          "testSuites": [{"tier": "public", "script": "test.sh"}],
          "timeLimitSeconds": 1,
          "makefile": null
        }
        """#.utf8))
    }

    private func makeJob(submissionID: String = "sub_worker_fail") throws -> Job {
        Job(
            submissionID: submissionID,
            testSetupID: "setup_worker_fail",
            attemptNumber: 2,
            submissionURL: URL(string: "http://127.0.0.1:1/submission.zip")!,
            testSetupURL: URL(string: "http://127.0.0.1:1/testsetup.zip")!,
            manifest: try makeManifest(),
            submissionFilename: "submission.ipynb"
        )
    }

    private func notebookJSON(code: String) -> String {
        """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","metadata":{},"source":[\(code.debugDescription)]}]}
        """
    }

    private func makeZip(at zipPath: String, files: [(path: String, contents: String)]) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worker-daemon-zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for file in files {
            let path = tempDir.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(file.contents.utf8).write(to: path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.currentDirectoryURL = tempDir
        process.arguments = [
            "python3",
            "-c",
            #"""
import os
import sys
import zipfile

zip_path = sys.argv[1]
root = sys.argv[2]

with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for current_root, _, filenames in os.walk(root):
        for filename in filenames:
            full_path = os.path.join(current_root, filename)
            archive_name = os.path.relpath(full_path, root)
            archive.write(full_path, archive_name)
"""#,
            zipPath,
            tempDir.path
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func makeServedJob(
        root: URL,
        serverPort: Int,
        submissionID: String
    ) throws -> Job {
        let submissionPath = root.appendingPathComponent("\(submissionID).ipynb")
        try Data(notebookJSON(code: "print(\(submissionID.debugDescription))\n").utf8).write(to: submissionPath)

        let setupZipPath = root.appendingPathComponent("\(submissionID)-setup.zip").path
        try makeZip(at: setupZipPath, files: [
            ("test.sh", "#!/bin/sh\necho passed\n")
        ])

        return Job(
            submissionID: submissionID,
            testSetupID: "setup-\(submissionID)",
            attemptNumber: 1,
            submissionURL: URL(string: "http://127.0.0.1:\(serverPort)/\(submissionID).ipynb")!,
            testSetupURL: URL(string: "http://127.0.0.1:\(serverPort)/\(submissionID)-setup.zip")!,
            manifest: try makeManifest(),
            submissionFilename: "submission.ipynb"
        )
    }

    private func waitUntil(
        timeoutSeconds: TimeInterval = 2,
        pollIntervalNanos: UInt64 = 50_000_000,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanos)
        }
        return await condition()
    }

    private func withEnvironment(
        _ values: [String: String],
        perform: () async throws -> Void
    ) async throws {
        let originals = Dictionary(uniqueKeysWithValues: values.keys.map { key in
            (key, ProcessInfo.processInfo.environment[key])
        })

        for (key, value) in values {
            setEnvironmentValue(value, forKey: key)
        }
        defer {
            for (key, original) in originals {
                setEnvironmentValue(original, forKey: key)
            }
        }

        try await perform()
    }

    private func setEnvironmentValue(_ value: String?, forKey key: String) {
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }

    func testWorkerDaemonCanBeCancelledWhilePollingForNoWork() async throws {
        let poller = MockPoller(jobs: Array(repeating: nil, count: 50))
        let reporter = MockReporter()
        let runner = MockRunner(output: ScriptOutput(exitCode: 0, stdout: "", stderr: "", executionTimeMs: 1, timedOut: false))
        let daemon = WorkerDaemon(
            poller: poller,
            reporter: reporter,
            runner: runner,
            apiBaseURL: URL(string: "http://localhost:8080")!,
            workerID: "worker-cancel",
            workerSecret: "secret",
            maxConcurrentJobs: 1,
            runnerProfile: nil
        )

        let task = Task {
            try await daemon.run()
        }

        let didPoll = await waitUntil {
            await poller.observedRequestCount() > 0
        }
        XCTAssertTrue(didPoll, "Daemon should poll for work before cancellation")

        task.cancel()
        do {
            try await task.value
        } catch is CancellationError {
            // Expected: the sleeping worker loop cooperatively exits on cancellation.
        }

        let requestCount = await poller.observedRequestCount()
        XCTAssertGreaterThan(requestCount, 0)
    }

    func testWorkerDaemonReportsSyntheticFailureWhenProcessingThrows() async throws {
        let poller = MockPoller(jobs: [try makeJob(), nil, nil])
        let reporter = MockReporter()
        let runner = MockRunner(output: ScriptOutput(exitCode: 0, stdout: "", stderr: "", executionTimeMs: 1, timedOut: false))
        let daemon = WorkerDaemon(
            poller: poller,
            reporter: reporter,
            runner: runner,
            apiBaseURL: URL(string: "http://localhost:8080")!,
            workerID: "worker-failure",
            workerSecret: "secret",
            maxConcurrentJobs: 1,
            runnerProfile: nil,
            downloadRetryPolicy: fastRetryPolicy
        )

        let task = Task {
            try await daemon.run()
        }

        let didReport = await waitUntil(timeoutSeconds: 5) {
            await !reporter.snapshot().isEmpty
        }
        XCTAssertTrue(didReport, "Expected fallback failure report after processing error")

        task.cancel()
        do {
            try await task.value
        } catch is CancellationError {
            // Expected on cooperative shutdown.
        }

        let reports = await reporter.snapshot()
        XCTAssertEqual(reports.count, 1)
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.submissionID, "sub_worker_fail")
        XCTAssertEqual(report.testSetupID, "setup_worker_fail")
        XCTAssertEqual(report.attemptNumber, 2)
        XCTAssertEqual(report.buildStatus, .failed)
        XCTAssertEqual(report.totalTests, 0)
        XCTAssertEqual(report.errorCount, 1)
        let compilerOutput = report.compilerOutput ?? ""
        XCTAssertTrue(
            compilerOutput.contains("Could not connect to the server")
                || compilerOutput.contains("NSURLErrorDomain"),
            "Expected propagated download failure details, got: \(compilerOutput)"
        )

        let runnerInvocations = await runner.observedInvocationCount()
        XCTAssertEqual(runnerInvocations, 0, "Runner should not execute when downloads fail first")
    }

    func testWorkerDaemonReportsFallbackFailureWhenFinalReportFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("worker-daemon-report-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let server = try StaticFileServer(directory: root)
        defer { server.stop() }

        let job = try makeServedJob(root: root, serverPort: server.port, submissionID: "sub_report_fail")
        let poller = MockPoller(jobs: [job, nil, nil, nil])
        let reporter = FlakyReporter(failuresRemaining: 1)
        let runner = MockRunner(output: ScriptOutput(
            exitCode: 0,
            stdout: "pass",
            stderr: "",
            executionTimeMs: 5,
            timedOut: false
        ))
        let daemon = WorkerDaemon(
            poller: poller,
            reporter: reporter,
            runner: runner,
            apiBaseURL: URL(string: "http://localhost:8080")!,
            workerID: "worker-report-fail",
            workerSecret: "secret",
            maxConcurrentJobs: 1,
            runnerProfile: nil,
            downloadRetryPolicy: fastRetryPolicy
        )

        let task = Task {
            try await daemon.run()
        }

        let didReport = await waitUntil(timeoutSeconds: 5) {
            await !reporter.snapshot().isEmpty
        }
        XCTAssertTrue(didReport, "Expected fallback report after reporter failure")

        task.cancel()
        do {
            try await task.value
        } catch is CancellationError {
        }

        let reports = await reporter.snapshot()
        let attemptCount = await reporter.observedAttempts()
        let runnerInvocations = await runner.observedInvocationCount()
        let pollCount = await poller.observedRequestCount()
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(attemptCount, 2)
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.submissionID, "sub_report_fail")
        XCTAssertEqual(report.buildStatus, .failed)
        XCTAssertEqual(report.totalTests, 0)
        XCTAssertEqual(report.errorCount, 1)
        XCTAssertTrue(report.compilerOutput?.contains("temporary failure") == true)
        XCTAssertEqual(runnerInvocations, 1)
        XCTAssertGreaterThan(pollCount, 1)
    }

    func testWorkerDaemonContinuesToNextJobAfterProcessingFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("worker-daemon-next-job-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let server = try StaticFileServer(directory: root)
        defer { server.stop() }

        let goodJob = try makeServedJob(root: root, serverPort: server.port, submissionID: "sub_good_job")
        let badJob = try makeJob(submissionID: "sub_bad_job")
        let poller = MockPoller(jobs: [badJob, goodJob, nil, nil, nil])
        let reporter = MockReporter()
        let runner = MockRunner(output: ScriptOutput(
            exitCode: 0,
            stdout: "all good",
            stderr: "",
            executionTimeMs: 7,
            timedOut: false
        ))
        let daemon = WorkerDaemon(
            poller: poller,
            reporter: reporter,
            runner: runner,
            apiBaseURL: URL(string: "http://localhost:8080")!,
            workerID: "worker-next-job",
            workerSecret: "secret",
            maxConcurrentJobs: 1,
            runnerProfile: nil,
            downloadRetryPolicy: fastRetryPolicy
        )

        let task = Task {
            try await daemon.run()
        }

        let didProcessBoth = await waitUntil(timeoutSeconds: 5) {
            await reporter.snapshot().count == 2
        }
        XCTAssertTrue(didProcessBoth, "Expected daemon to report both failed and successful jobs")

        task.cancel()
        do {
            try await task.value
        } catch is CancellationError {
        }

        let reports = await reporter.snapshot()
        let runnerInvocations = await runner.observedInvocationCount()
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports[0].submissionID, "sub_bad_job")
        XCTAssertEqual(reports[0].buildStatus, .failed)
        XCTAssertEqual(reports[0].errorCount, 1)

        XCTAssertEqual(reports[1].submissionID, "sub_good_job")
        XCTAssertEqual(reports[1].buildStatus, .passed)
        XCTAssertEqual(reports[1].totalTests, 1)
        XCTAssertEqual(reports[1].passCount, 1)
        XCTAssertEqual(runnerInvocations, 1)
    }

    func testWorkerDaemonHeartbeatFailuresDoNotStopPolling() async throws {
        let poller = MockPoller(jobs: Array(repeating: nil, count: 50))
        let reporter = FlakyReporter(failuresRemaining: 0, heartbeatFailuresRemaining: 2)
        let runner = MockRunner(output: ScriptOutput(exitCode: 0, stdout: "", stderr: "", executionTimeMs: 1, timedOut: false))
        let daemon = WorkerDaemon(
            poller: poller,
            reporter: reporter,
            runner: runner,
            apiBaseURL: URL(string: "http://localhost:8080")!,
            workerID: "worker-heartbeat-retry",
            workerSecret: "secret",
            maxConcurrentJobs: 1,
            runnerProfile: nil
        )

        let heartbeatTask = Task {
            try? await daemon.sendHeartbeat()
        }

        let runTask = Task {
            try await daemon.run()
        }

        let didKeepPolling = await waitUntil(timeoutSeconds: 4) {
            await poller.observedRequestCount() > 1
        }
        XCTAssertTrue(didKeepPolling, "Runner should continue polling while heartbeat retries fail")

        _ = await heartbeatTask.result
        runTask.cancel()
        _ = await runTask.result
    }

    func testDownloadRetriesThroughShortServerInterruption() async throws {
        let flakyServer = try FlakyHTTPServer(failuresBeforeSuccess: 2, responseBody: "PK\0\0")
        defer { flakyServer.stop() }

        let poller = MockPoller(jobs: [])
        let reporter = MockReporter()
        let runner = MockRunner(output: ScriptOutput(exitCode: 0, stdout: "", stderr: "", executionTimeMs: 1, timedOut: false))
        let daemon = WorkerDaemon(
            poller: poller,
            reporter: reporter,
            runner: runner,
            apiBaseURL: URL(string: "http://localhost:8080")!,
            workerID: "worker-download-retry",
            workerSecret: "secret",
            maxConcurrentJobs: 1,
            runnerProfile: nil,
            downloadRetryPolicy: generousRetryPolicy
        )

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-retry-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await daemon.download(
            url: URL(string: "http://127.0.0.1:\(flakyServer.port)/artifact.zip")!,
            to: destination
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testWorkerDaemonRetriesPollingAfterTransientHTTP500() async throws {
        try await withEnvironment([
            "RUNNER_RETRY_BASE_DELAY_MS": "10",
            "RUNNER_RETRY_MAX_DELAY_MS": "20",
        ]) {
            let poller = FlakyPoller(failuresRemaining: 2, failureMode: .http500)
            let reporter = MockReporter()
            let runner = MockRunner(output: ScriptOutput(exitCode: 0, stdout: "", stderr: "", executionTimeMs: 1, timedOut: false))
            let daemon = WorkerDaemon(
                poller: poller,
                reporter: reporter,
                runner: runner,
                apiBaseURL: URL(string: "http://localhost:8080")!,
                workerID: "worker-http500-retry",
                workerSecret: "secret",
                maxConcurrentJobs: 1,
                runnerProfile: nil
            )

            let task = Task {
                try await daemon.run()
            }

            let didKeepPolling = await waitUntil(timeoutSeconds: 4) {
                await poller.observedRequestCount() >= 3
            }
            XCTAssertTrue(didKeepPolling, "Runner should keep polling after transient HTTP 500 responses")

            task.cancel()
            _ = await task.result
        }
    }

    func testWorkerDaemonRetriesPollingAfterDuplicateWorkerIDConflict() async throws {
        try await withEnvironment([
            "RUNNER_RETRY_BASE_DELAY_MS": "10",
            "RUNNER_RETRY_MAX_DELAY_MS": "20",
        ]) {
            let poller = FlakyPoller(failuresRemaining: 2, failureMode: .duplicateWorkerID)
            let reporter = MockReporter()
            let runner = MockRunner(output: ScriptOutput(exitCode: 0, stdout: "", stderr: "", executionTimeMs: 1, timedOut: false))
            let daemon = WorkerDaemon(
                poller: poller,
                reporter: reporter,
                runner: runner,
                apiBaseURL: URL(string: "http://localhost:8080")!,
                workerID: "worker-duplicate-id-retry",
                workerSecret: "secret",
                maxConcurrentJobs: 1,
                runnerProfile: nil
            )

            let task = Task {
                try await daemon.run()
            }

            let didKeepPolling = await waitUntil(timeoutSeconds: 4) {
                await poller.observedRequestCount() >= 3
            }
            XCTAssertTrue(didKeepPolling, "Runner should keep polling after duplicate worker ID conflicts")

            task.cancel()
            _ = await task.result
        }
    }
}
