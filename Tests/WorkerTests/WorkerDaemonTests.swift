import XCTest
@testable import chickadee_runner
import Core
import Foundation
#if os(Linux)
import Glibc
#endif

final class WorkerDaemonTests: XCTestCase {

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

        func requestJob() async throws(JobPollerError) -> Job? {
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

    private actor MockReporter: Reporting {
        private var collections: [TestOutcomeCollection] = []

        func report(_ collection: TestOutcomeCollection) async throws(ReporterError) {
            collections.append(collection)
        }

        func snapshot() -> [TestOutcomeCollection] {
            collections
        }
    }

    private actor FlakyReporter: Reporting {
        private var failuresRemaining: Int
        private var attempts = 0
        private var collections: [TestOutcomeCollection] = []

        init(failuresRemaining: Int) {
            self.failuresRemaining = failuresRemaining
        }

        func report(_ collection: TestOutcomeCollection) async throws(ReporterError) {
            attempts += 1
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                throw ReporterError.httpError(500, "temporary failure")
            }
            collections.append(collection)
        }

        func observedAttempts() -> Int {
            attempts
        }

        func snapshot() -> [TestOutcomeCollection] {
            collections
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

    private func notebookJSON(markdown: String) -> String {
        """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"markdown","metadata":{},"source":[\(markdown.debugDescription)]}]}
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
        try Data(notebookJSON(markdown: submissionID).utf8).write(to: submissionPath)

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

    func testWorkerDaemonCanBeCancelledWhilePollingForNoWork() async throws {
        let poller = MockPoller(jobs: Array(repeating: nil, count: 50))
        let reporter = MockReporter()
        let runner = MockRunner(output: ScriptOutput(exitCode: 0, stdout: "", stderr: "", executionTimeMs: 1, timedOut: false))
        let daemon = WorkerDaemon(
            poller: poller,
            reporter: reporter,
            runner: runner,
            workerID: "worker-cancel",
            workerSecret: "secret",
            maxConcurrentJobs: 1
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
            workerID: "worker-failure",
            workerSecret: "secret",
            maxConcurrentJobs: 1
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
            workerID: "worker-report-fail",
            workerSecret: "secret",
            maxConcurrentJobs: 1
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
            workerID: "worker-next-job",
            workerSecret: "secret",
            maxConcurrentJobs: 1
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
}
