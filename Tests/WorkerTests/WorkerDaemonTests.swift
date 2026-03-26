import XCTest
@testable import chickadee_runner
import Core
import Foundation

final class WorkerDaemonTests: XCTestCase {

    private actor MockPoller: JobPolling {
        private var jobs: [Job?]
        private(set) var requestCount = 0

        init(jobs: [Job?]) {
            self.jobs = jobs
        }

        func requestJob() async throws -> Job? {
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

        func report(_ collection: TestOutcomeCollection) async throws {
            collections.append(collection)
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
}
