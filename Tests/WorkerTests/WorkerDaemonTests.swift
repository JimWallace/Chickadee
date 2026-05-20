import Core
import Foundation
import Testing

@testable import chickadee_runner

#if os(Linux)
import Glibc
#endif

@Suite struct WorkerDaemonTests {
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
                directory.path,
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
                throw IssueRecorded("python3 is unavailable for local static file serving")
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
            case http401
            case http403
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
                case .http401:
                    throw .httpError(401, "temporary unauthorized")
                case .http403:
                    throw .httpError(403, "temporary forbidden")
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

        func report(_ report: WorkerExecutionReport) async throws(ReporterError) {
            collections.append(report.collection)
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

        func report(_ report: WorkerExecutionReport) async throws(ReporterError) {
            attempts += 1
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                throw ReporterError.httpError(500, "temporary failure")
            }
            collections.append(report.collection)
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
                responseBody,
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
                throw IssueRecorded("python3 is unavailable for local flaky HTTP serving")
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

        func run(script: URL, workDir: URL, timeLimitSeconds: Int, env: [String: String]) async -> ScriptOutput {
            invocationCount += 1
            return output
        }

        func observedInvocationCount() -> Int {
            invocationCount
        }
    }

    private func makeManifest() throws -> TestProperties {
        try JSONDecoder().decode(
            TestProperties.self,
            from: Data(
                #"""
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
            submissionURL: testURL("http://127.0.0.1:1/submission.zip"),
            testSetupURL: testURL("http://127.0.0.1:1/testsetup.zip"),
            manifest: try makeManifest(),
            submissionFilename: "submission.ipynb"
        )
    }

    private func notebookJSON(code: String) -> String {
        """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","metadata":{},"source":[\(code.debugDescription)]}]}
        """
    }

    private func makeTempCacheRoot(named prefix: String) throws -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
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
            tempDir.path,
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func makeServedJob(
        root: URL,
        serverPort: Int,
        submissionID: String
    ) throws -> Job {
        let submissionPath = root.appendingPathComponent("\(submissionID).ipynb")
        try Data(notebookJSON(code: "print(\(submissionID.debugDescription))\n").utf8).write(to: submissionPath)

        let setupZipPath = root.appendingPathComponent("\(submissionID)-setup.zip").path
        try makeZip(
            at: setupZipPath,
            files: [
                ("test.sh", "#!/bin/sh\necho passed\n")
            ])

        return Job(
            submissionID: submissionID,
            testSetupID: "setup-\(submissionID)",
            attemptNumber: 1,
            submissionURL: testURL("http://127.0.0.1:\(serverPort)/\(submissionID).ipynb"),
            testSetupURL: testURL("http://127.0.0.1:\(serverPort)/\(submissionID)-setup.zip"),
            manifest: try makeManifest(),
            submissionFilename: "submission.ipynb"
        )
    }

    // Generous default: `waitUntil` short-circuits the instant `condition`
    // holds, so a large ceiling adds nothing to passing runs — it only buys
    // slack on a loaded machine.  These gates spawn `Task { daemon.run() }`
    // and wait for it to poll; under the cold-cache nightly's saturated
    // cooperative thread pool (every one of ~1280 tests running in parallel,
    // plus blocking Thread.sleep in mocks/teardown) that Task can be starved
    // for several seconds before it gets to run.  A tight 2–4s window made
    // these tests flaky there; 10s removes the class of failure.
    private func waitUntil(
        timeoutSeconds: TimeInterval = 10,
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
        let originals = Dictionary(
            uniqueKeysWithValues: values.keys.map { key in
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

    @Test func workerDaemonCanBeCancelledWhilePollingForNoWork() async throws {
        let poller = MockPoller(jobs: Array(repeating: nil, count: 50))
        let reporter = MockReporter()
        let runner = MockRunner(
            output: ScriptOutput(exitCode: 0, stdout: "", stderr: "", executionTimeMs: 1, timedOut: false))
        let daemon = WorkerDaemon(
            poller: poller,
            reporter: reporter,
            runner: runner,
            apiBaseURL: testURL("http://localhost:8080"),
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
        #expect(didPoll, "Daemon should poll for work before cancellation")

        task.cancel()
        do {
            try await task.value
        } catch is CancellationError {
            // Expected: the sleeping worker loop cooperatively exits on cancellation.
        }

        let requestCount = await poller.observedRequestCount()
        #expect(requestCount > 0)
    }

    @Test func workerDaemonReportsSyntheticFailureWhenProcessingThrows() async throws {
        let poller = MockPoller(jobs: [try makeJob(), nil, nil])
        let reporter = MockReporter()
        let runner = MockRunner(
            output: ScriptOutput(exitCode: 0, stdout: "", stderr: "", executionTimeMs: 1, timedOut: false))
        let daemon = WorkerDaemon(
            poller: poller,
            reporter: reporter,
            runner: runner,
            apiBaseURL: testURL("http://localhost:8080"),
            workerID: "worker-failure",
            workerSecret: "secret",
            maxConcurrentJobs: 1,
            runnerProfile: nil,
            downloadRetryPolicy: fastRetryPolicy
        )

        let task = Task {
            try await daemon.run()
        }

        let didReport = await waitUntil(timeoutSeconds: 10) {
            await !reporter.snapshot().isEmpty
        }
        #expect(didReport, "Expected fallback failure report after processing error")

        task.cancel()
        do {
            try await task.value
        } catch is CancellationError {
            // Expected on cooperative shutdown.
        }

        let reports = await reporter.snapshot()
        #expect(reports.count == 1)
        let report = try #require(reports.first)
        #expect(report.submissionID == "sub_worker_fail")
        #expect(report.testSetupID == "setup_worker_fail")
        #expect(report.attemptNumber == 2)
        #expect(report.buildStatus == .failed)
        #expect(report.totalTests == 0)
        #expect(report.errorCount == 1)
        let compilerOutput = report.compilerOutput ?? ""
        #expect(
            compilerOutput.contains("Could not connect to the server")
                || compilerOutput.contains("NSURLErrorDomain"),
            "Expected propagated download failure details, got: \(compilerOutput)"
        )

        let runnerInvocations = await runner.observedInvocationCount()
        #expect(runnerInvocations == 0, "Runner should not execute when downloads fail first")
    }

    @Test func workerDaemonReportsFallbackFailureWhenFinalReportFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("worker-daemon-report-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheRoot = try makeTempCacheRoot(named: "worker-daemon-report-failure-cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let server = try StaticFileServer(directory: root)
        defer { server.stop() }

        let job = try makeServedJob(root: root, serverPort: server.port, submissionID: "sub_report_fail")
        let poller = MockPoller(jobs: [job, nil, nil, nil])
        let reporter = FlakyReporter(failuresRemaining: 1)
        let runner = MockRunner(
            output: ScriptOutput(
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
            apiBaseURL: testURL("http://localhost:8080"),
            workerID: "worker-report-fail",
            workerSecret: "secret",
            maxConcurrentJobs: 1,
            runnerProfile: nil,
            downloadRetryPolicy: fastRetryPolicy,
            testSetupCache: TestSetupCache(cacheRoot: cacheRoot)
        )

        let task = Task {
            try await daemon.run()
        }

        let didReport = await waitUntil(timeoutSeconds: 10) {
            await !reporter.snapshot().isEmpty
        }
        #expect(didReport, "Expected fallback report after reporter failure")

        // Wait for the daemon to come back around for its second poll
        // (post-job-completion).  Under slow CI runners `task.cancel()`
        // could otherwise race the daemon's poll-loop resumption and
        // leave pollCount stuck at 1.
        let didPollAgain = await waitUntil(timeoutSeconds: 10) {
            await poller.observedRequestCount() > 1
        }
        #expect(didPollAgain, "Expected daemon to resume polling after first job")

        task.cancel()
        do {
            try await task.value
        } catch is CancellationError {
        }

        let reports = await reporter.snapshot()
        let attemptCount = await reporter.observedAttempts()
        let runnerInvocations = await runner.observedInvocationCount()
        let pollCount = await poller.observedRequestCount()
        #expect(reports.count == 1)
        #expect(attemptCount == 2)
        let report = try #require(reports.first)
        #expect(report.submissionID == "sub_report_fail")
        #expect(report.buildStatus == .failed)
        #expect(report.totalTests == 0)
        #expect(report.errorCount == 1)
        #expect(report.compilerOutput?.contains("temporary failure") == true)
        #expect(runnerInvocations == 1)
        #expect(pollCount > 1)
    }

    @Test func workerDaemonContinuesToNextJobAfterProcessingFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("worker-daemon-next-job-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheRoot = try makeTempCacheRoot(named: "worker-daemon-next-job-cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let server = try StaticFileServer(directory: root)
        defer { server.stop() }

        let goodJob = try makeServedJob(root: root, serverPort: server.port, submissionID: "sub_good_job")
        let badJob = try makeJob(submissionID: "sub_bad_job")
        let poller = MockPoller(jobs: [badJob, goodJob, nil, nil, nil])
        let reporter = MockReporter()
        let runner = MockRunner(
            output: ScriptOutput(
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
            apiBaseURL: testURL("http://localhost:8080"),
            workerID: "worker-next-job",
            workerSecret: "secret",
            maxConcurrentJobs: 1,
            runnerProfile: nil,
            downloadRetryPolicy: fastRetryPolicy,
            testSetupCache: TestSetupCache(cacheRoot: cacheRoot)
        )

        let task = Task {
            try await daemon.run()
        }

        let didProcessBoth = await waitUntil(timeoutSeconds: 10) {
            await reporter.snapshot().count == 2
        }
        #expect(didProcessBoth, "Expected daemon to report both failed and successful jobs")

        task.cancel()
        do {
            try await task.value
        } catch is CancellationError {
        }

        let reports = await reporter.snapshot()
        let runnerInvocations = await runner.observedInvocationCount()
        #expect(reports.count == 2)
        #expect(reports[0].submissionID == "sub_bad_job")
        #expect(reports[0].buildStatus == .failed)
        #expect(reports[0].errorCount == 1)

        #expect(reports[1].submissionID == "sub_good_job")
        #expect(reports[1].buildStatus == .passed)
        #expect(reports[1].totalTests == 1)
        #expect(reports[1].passCount == 1)
        #expect(runnerInvocations == 1)
    }

    @Test func jSONFooterStrippedFromLongResult() async throws {
        // When a test script emits human-readable output followed by a JSON footer line,
        // the JSON footer must NOT appear in longResult shown to students.
        // Only the human-readable lines should be visible.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("worker-daemon-json-footer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheRoot = try makeTempCacheRoot(named: "worker-daemon-json-footer-cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let server = try StaticFileServer(directory: root)
        defer { server.stop() }

        let job = try makeServedJob(root: root, serverPort: server.port, submissionID: "sub_json_footer")

        let stdoutWithFooter = """
            Hello, World!
            Some diagnostic output here.
            {"shortResult": "3/4 cases passed", "score": 0.75}
            """

        let poller = MockPoller(jobs: [job, nil])
        let reporter = MockReporter()
        let runner = MockRunner(
            output: ScriptOutput(
                exitCode: 1,  // fail so longResult is populated
                stdout: stdoutWithFooter,
                stderr: "",
                executionTimeMs: 10,
                timedOut: false
            ))
        let daemon = WorkerDaemon(
            poller: poller,
            reporter: reporter,
            runner: runner,
            apiBaseURL: testURL("http://localhost:8080"),
            workerID: "worker-json-footer",
            workerSecret: "secret",
            maxConcurrentJobs: 1,
            runnerProfile: nil,
            downloadRetryPolicy: fastRetryPolicy,
            testSetupCache: TestSetupCache(cacheRoot: cacheRoot)
        )

        let task = Task { try await daemon.run() }
        _ = await waitUntil(timeoutSeconds: 10) { await reporter.snapshot().count == 1 }
        task.cancel()
        try? await task.value

        let reports = await reporter.snapshot()
        let report = try #require(reports.first)
        #expect(report.outcomes.count == 1)

        let outcome = try #require(report.outcomes.first)
        // shortResult must be extracted from the JSON footer
        #expect(outcome.shortResult == "3/4 cases passed")

        // longResult must contain the human-readable lines…
        let longResult = try #require(outcome.longResult)
        #expect(
            longResult.contains("Hello, World!"),
            "Human-readable stdout must appear in longResult")
        #expect(
            longResult.contains("Some diagnostic output here."),
            "All human-readable lines must appear in longResult")

        // …but must NOT contain the raw JSON footer
        #expect(
            longResult.contains("shortResult") == false,
            "JSON footer must be stripped from longResult shown to students")
        #expect(
            longResult.contains("{") == false,
            "No JSON braces should appear in longResult"
        )
    }

    @Test func workerDaemonHeartbeatFailuresDoNotStopPolling() async throws {
        let poller = MockPoller(jobs: Array(repeating: nil, count: 50))
        let reporter = FlakyReporter(failuresRemaining: 0, heartbeatFailuresRemaining: 2)
        let runner = MockRunner(
            output: ScriptOutput(exitCode: 0, stdout: "", stderr: "", executionTimeMs: 1, timedOut: false))
        let daemon = WorkerDaemon(
            poller: poller,
            reporter: reporter,
            runner: runner,
            apiBaseURL: testURL("http://localhost:8080"),
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

        let didKeepPolling = await waitUntil(timeoutSeconds: 10) {
            await poller.observedRequestCount() > 1
        }
        #expect(didKeepPolling, "Runner should continue polling while heartbeat retries fail")

        _ = await heartbeatTask.result
        runTask.cancel()
        _ = await runTask.result
    }

    @Test func downloadRetriesThroughShortServerInterruption() async throws {
        let flakyServer = try FlakyHTTPServer(failuresBeforeSuccess: 2, responseBody: "PK\0\0")
        defer { flakyServer.stop() }

        let poller = MockPoller(jobs: [])
        let reporter = MockReporter()
        let runner = MockRunner(
            output: ScriptOutput(exitCode: 0, stdout: "", stderr: "", executionTimeMs: 1, timedOut: false))
        let daemon = WorkerDaemon(
            poller: poller,
            reporter: reporter,
            runner: runner,
            apiBaseURL: testURL("http://localhost:8080"),
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
            url: testURL("http://127.0.0.1:\(flakyServer.port)/artifact.zip"),
            to: destination
        )

        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func workerDaemonRetriesPollingAfterTransientHTTP500() async throws {
        try await withEnvironment([
            "RUNNER_RETRY_BASE_DELAY_MS": "10",
            "RUNNER_RETRY_MAX_DELAY_MS": "20",
        ]) {
            let poller = FlakyPoller(failuresRemaining: 2, failureMode: .http500)
            let reporter = MockReporter()
            let runner = MockRunner(
                output: ScriptOutput(exitCode: 0, stdout: "", stderr: "", executionTimeMs: 1, timedOut: false))
            let daemon = WorkerDaemon(
                poller: poller,
                reporter: reporter,
                runner: runner,
                apiBaseURL: testURL("http://localhost:8080"),
                workerID: "worker-http500-retry",
                workerSecret: "secret",
                maxConcurrentJobs: 1,
                runnerProfile: nil
            )

            let task = Task {
                try await daemon.run()
            }

            let didKeepPolling = await waitUntil(timeoutSeconds: 10) {
                await poller.observedRequestCount() >= 3
            }
            #expect(didKeepPolling, "Runner should keep polling after transient HTTP 500 responses")

            task.cancel()
            _ = await task.result
        }
    }

    @Test func workerDaemonRetriesPollingAfterTransientHTTP401() async throws {
        try await withEnvironment([
            "RUNNER_RETRY_BASE_DELAY_MS": "10",
            "RUNNER_RETRY_MAX_DELAY_MS": "20",
        ]) {
            let poller = FlakyPoller(failuresRemaining: 2, failureMode: .http401)
            let reporter = MockReporter()
            let runner = MockRunner(
                output: ScriptOutput(exitCode: 0, stdout: "", stderr: "", executionTimeMs: 1, timedOut: false))
            let daemon = WorkerDaemon(
                poller: poller,
                reporter: reporter,
                runner: runner,
                apiBaseURL: testURL("http://localhost:8080"),
                workerID: "worker-http401-retry",
                workerSecret: "secret",
                maxConcurrentJobs: 1,
                runnerProfile: nil
            )

            let task = Task {
                try await daemon.run()
            }

            let didKeepPolling = await waitUntil(timeoutSeconds: 10) {
                await poller.observedRequestCount() >= 3
            }
            #expect(didKeepPolling, "Runner should keep polling after transient HTTP 401 responses")

            task.cancel()
            _ = await task.result
        }
    }

    @Test func workerDaemonRetriesPollingAfterDuplicateWorkerIDConflict() async throws {
        try await withEnvironment([
            "RUNNER_RETRY_BASE_DELAY_MS": "10",
            "RUNNER_RETRY_MAX_DELAY_MS": "20",
        ]) {
            let poller = FlakyPoller(failuresRemaining: 2, failureMode: .duplicateWorkerID)
            let reporter = MockReporter()
            let runner = MockRunner(
                output: ScriptOutput(exitCode: 0, stdout: "", stderr: "", executionTimeMs: 1, timedOut: false))
            let daemon = WorkerDaemon(
                poller: poller,
                reporter: reporter,
                runner: runner,
                apiBaseURL: testURL("http://localhost:8080"),
                workerID: "worker-duplicate-id-retry",
                workerSecret: "secret",
                maxConcurrentJobs: 1,
                runnerProfile: nil
            )

            let task = Task {
                try await daemon.run()
            }

            let didKeepPolling = await waitUntil(timeoutSeconds: 10) {
                await poller.observedRequestCount() >= 3
            }
            #expect(didKeepPolling, "Runner should keep polling after duplicate worker ID conflicts")

            task.cancel()
            _ = await task.result
        }
    }

    // MARK: - Concurrency / state-transition coverage (round 2)

    /// Records the peak number of simultaneous `run(...)` invocations so a
    /// concurrency test can prove the daemon's worker-loop fanout actually
    /// processes jobs in parallel.  Holds each invocation open for `delay`
    /// so the time window for overlap is reliable.
    private actor ConcurrencyRecordingRunner: ScriptRunner {
        private var activeCount = 0
        private var maxObserved = 0
        private var totalCompletions = 0
        private let output: ScriptOutput
        private let delay: Duration

        init(output: ScriptOutput, delay: Duration) {
            self.output = output
            self.delay = delay
        }

        func run(
            script: URL, workDir: URL, timeLimitSeconds: Int, env: [String: String]
        ) async -> ScriptOutput {
            activeCount += 1
            maxObserved = Swift.max(maxObserved, activeCount)
            try? await Task.sleep(for: delay)
            activeCount -= 1
            totalCompletions += 1
            return output
        }

        func snapshot() -> (maxConcurrent: Int, total: Int) {
            (maxObserved, totalCompletions)
        }
    }

    /// Always returns a 4xx terminal HTTP error for submission downloads.
    /// Lets us exercise the "submission download terminally fails →
    /// daemon still reports a synthetic failure and keeps polling" path
    /// without needing a real flaky server.
    private final class AlwaysFails404Server {
        let process: Process
        let port: Int
        private let stdout: Pipe

        init() throws {
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

                class Handler(http.server.BaseHTTPRequestHandler):
                    def do_GET(self):
                        self.send_response(404)
                        self.end_headers()
                        self.wfile.write(b"not found")
                    def log_message(self, format, *args):
                        pass

                with socketserver.TCPServer(("127.0.0.1", 0), Handler) as httpd:
                    print(httpd.server_address[1], flush=True)
                    httpd.serve_forever()
                """#,
            ]
            try process.run()
            let data = stdout.fileHandleForReading.availableData
            guard
                let line = String(data: data, encoding: .utf8)?.split(separator: "\n").first,
                let port = Int(line)
            else {
                process.terminate()
                throw IssueRecorded("python3 is unavailable for always-404 server")
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

    /// With `maxConcurrentJobs > 1`, the daemon should actually run more
    /// than one job at a time — not serialize them through a single
    /// worker loop.  This test feeds 5 jobs and a 100 ms per-job delay,
    /// then asserts the recording runner observed at least 2 concurrent
    /// invocations (more is fine; less means the worker-loop fanout
    /// regressed).
    @Test func workerDaemonRunsJobsConcurrentlyWhenMaxConcurrentJobsAllows() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("worker-daemon-concurrent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheRoot = try makeTempCacheRoot(named: "worker-daemon-concurrent-cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let server = try StaticFileServer(directory: root)
        defer { server.stop() }

        let jobs = try (0..<5).map { i in
            try makeServedJob(root: root, serverPort: server.port, submissionID: "concurrent_\(i)")
        }
        let poller = MockPoller(jobs: jobs.map(Optional.some) + [nil])
        let reporter = MockReporter()
        let runner = ConcurrencyRecordingRunner(
            output: ScriptOutput(exitCode: 0, stdout: "passed", stderr: "", executionTimeMs: 1, timedOut: false),
            delay: .milliseconds(100)
        )
        let daemon = WorkerDaemon(
            poller: poller,
            reporter: reporter,
            runner: runner,
            apiBaseURL: testURL("http://localhost:8080"),
            workerID: "worker-concurrent",
            workerSecret: "secret",
            maxConcurrentJobs: 5,
            runnerProfile: nil,
            downloadRetryPolicy: fastRetryPolicy,
            testSetupCache: TestSetupCache(cacheRoot: cacheRoot)
        )

        let task = Task { try await daemon.run() }
        _ = await waitUntil(timeoutSeconds: 10) { await reporter.snapshot().count == 5 }
        task.cancel()
        try? await task.value

        let (maxConcurrent, total) = await runner.snapshot()
        #expect(total == 5, "all 5 jobs should have completed")
        #expect(
            maxConcurrent >= 2,
            "expected >= 2 concurrent script invocations, got \(maxConcurrent); fanout may have regressed"
        )
    }

    /// When the submission download terminally fails (404, not a retryable
    /// 5xx), the daemon should still finish the job with a synthetic
    /// failure report rather than crashing or silently skipping the job,
    /// AND continue polling for the next job.  Complements
    /// `testDownloadRetriesThroughShortServerInterruption` which covers
    /// the *recoverable* download failure path.
    @Test func workerDaemonReportsSyntheticFailureWhenSubmissionDownloadTerminallyFails() async throws {
        let cacheRoot = try makeTempCacheRoot(named: "worker-daemon-dl-terminal-cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let failServer = try AlwaysFails404Server()
        defer { failServer.stop() }

        let job = Job(
            submissionID: "sub_dl_terminal",
            testSetupID: "setup_dl_terminal",
            attemptNumber: 1,
            submissionURL: testURL("http://127.0.0.1:\(failServer.port)/submission.zip"),
            testSetupURL: testURL("http://127.0.0.1:\(failServer.port)/testsetup.zip"),
            manifest: try makeManifest(),
            submissionFilename: "submission.ipynb"
        )
        let poller = MockPoller(jobs: [job, nil])
        let reporter = MockReporter()
        let runner = MockRunner(
            output: ScriptOutput(exitCode: 0, stdout: "", stderr: "", executionTimeMs: 1, timedOut: false))
        let daemon = WorkerDaemon(
            poller: poller,
            reporter: reporter,
            runner: runner,
            apiBaseURL: testURL("http://localhost:8080"),
            workerID: "worker-dl-terminal",
            workerSecret: "secret",
            maxConcurrentJobs: 1,
            runnerProfile: nil,
            downloadRetryPolicy: fastRetryPolicy,
            testSetupCache: TestSetupCache(cacheRoot: cacheRoot)
        )

        let task = Task { try await daemon.run() }
        _ = await waitUntil(timeoutSeconds: 10) { await reporter.snapshot().count == 1 }
        task.cancel()
        try? await task.value

        let reports = await reporter.snapshot()
        #expect(reports.count == 1, "should still produce a report for the failed job")
        let report = try #require(reports.first)
        #expect(report.submissionID == "sub_dl_terminal")
        #expect(report.buildStatus == .failed, "terminal download failure should surface as buildStatus=.failed")
        #expect(report.outcomes.isEmpty, "no outcomes when build fails")
        let runnerInvocations = await runner.observedInvocationCount()
        #expect(runnerInvocations == 0, "ScriptRunner should not have been invoked when the submission download failed")
    }
}
