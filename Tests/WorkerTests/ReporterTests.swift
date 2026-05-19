import Core
import Foundation
import Testing

@testable import chickadee_runner

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Unit tests for `Reporter`. Network I/O is intercepted via `MockURLProtocol`
/// so retry classification, retry exhaustion, and wire format are exercised
/// without sockets. All tests use zero-delay retry policies for determinism.
///
/// `ReporterError.unexpectedResponse` is deliberately not covered here — it
/// only fires when `URLSession` returns a non-HTTP `URLResponse`, which the
/// HTTP-only URLProtocol pipeline doesn't produce.
@Suite(.serialized) struct ReporterTests {

    private let apiBaseURL = URL(string: "https://server.test")!

    // MARK: report() — happy path

    @Test func report_succeedsOn200() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(200))
            let reporter = makeReporter()
            try await reporter.report(sampleExecutionReport())
            #expect(MockURLProtocol.capturedRequests.count == 1)

        }
    }

    // MARK: report() — wire format

    @Test func report_sendsSignedPOST_toResultsEndpoint() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(200))
            let reporter = makeReporter(workerID: "runner-3")
            try await reporter.report(sampleExecutionReport())

            let captured = try #require(MockURLProtocol.capturedRequests.first)
            #expect(captured.url?.path == "/api/v1/worker/results")
            #expect(captured.httpMethod == "POST")
            #expect(captured.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(captured.value(forHTTPHeaderField: "X-Worker-Signature") != nil)
            #expect(captured.value(forHTTPHeaderField: "X-Worker-Timestamp") != nil)
            #expect(captured.value(forHTTPHeaderField: "X-Worker-Nonce") != nil)
            #expect(captured.value(forHTTPHeaderField: "X-Worker-Body-SHA256") != nil)
            #expect(captured.value(forHTTPHeaderField: "X-Worker-Id") == "runner-3")

            let body = try #require(MockURLProtocol.capturedBodies.first)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(WorkerExecutionReport.self, from: body)
            #expect(decoded.collection.submissionID == "sub_42")

        }
    }

    @Test func report_convenienceOverload_wrapsCollection() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(200))
            let reporter = makeReporter()
            let collection = sampleCollection()
            try await reporter.report(collection)

            let body = try #require(MockURLProtocol.capturedBodies.first)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(WorkerExecutionReport.self, from: body)
            #expect(decoded.collection.submissionID == collection.submissionID)
            #expect(decoded.diagnostics == nil)

        }
    }

    // MARK: report() — retry recovery

    @Test func report_retriesOn500_thenSucceeds() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(500))
            MockURLProtocol.enqueue(.status(200))
            let reporter = makeReporter(uploadMaxAttempts: 3)
            try await reporter.report(sampleExecutionReport())
            #expect(MockURLProtocol.capturedRequests.count == 2)

        }
    }

    @Test func report_retriesOnTransportError_thenSucceeds() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.failure(URLError(.notConnectedToInternet)))
            MockURLProtocol.enqueue(.status(200))
            let reporter = makeReporter(uploadMaxAttempts: 3)
            try await reporter.report(sampleExecutionReport())
            #expect(MockURLProtocol.capturedRequests.count == 2)

        }
    }

    @Test func report_retriesOn429() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(429))
            MockURLProtocol.enqueue(.status(200))
            let reporter = makeReporter(uploadMaxAttempts: 3)
            try await reporter.report(sampleExecutionReport())
            #expect(MockURLProtocol.capturedRequests.count == 2)

        }
    }

    @Test func report_retriesOn503() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(503))
            MockURLProtocol.enqueue(.status(200))
            let reporter = makeReporter(uploadMaxAttempts: 3)
            try await reporter.report(sampleExecutionReport())
            #expect(MockURLProtocol.capturedRequests.count == 2)

        }
    }

    @Test func report_retriesOn504() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(504))
            MockURLProtocol.enqueue(.status(200))
            let reporter = makeReporter(uploadMaxAttempts: 3)
            try await reporter.report(sampleExecutionReport())
            #expect(MockURLProtocol.capturedRequests.count == 2)

        }
    }

    // MARK: report() — terminal classifications

    @Test func report_terminatesOn401() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(401, body: Data("unauthorized".utf8)))
            let reporter = makeReporter(uploadMaxAttempts: 5)
            await expectHTTPError(401) { try await reporter.report(self.sampleExecutionReport()) }
            #expect(MockURLProtocol.capturedRequests.count == 1)

        }
    }

    @Test func report_terminatesOn403() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(403))
            let reporter = makeReporter(uploadMaxAttempts: 5)
            await expectHTTPError(403) { try await reporter.report(self.sampleExecutionReport()) }
            #expect(MockURLProtocol.capturedRequests.count == 1)

        }
    }

    @Test func report_terminatesOn409() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(409))
            let reporter = makeReporter(uploadMaxAttempts: 5)
            await expectHTTPError(409) { try await reporter.report(self.sampleExecutionReport()) }
            #expect(MockURLProtocol.capturedRequests.count == 1)

        }
    }

    @Test func report_terminatesOn400_default() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(400))
            let reporter = makeReporter(uploadMaxAttempts: 5)
            await expectHTTPError(400) { try await reporter.report(self.sampleExecutionReport()) }
            #expect(MockURLProtocol.capturedRequests.count == 1)

        }
    }

    // MARK: report() — retry exhaustion

    @Test func report_failsAfterMaxAttempts() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            for _ in 0..<5 { MockURLProtocol.enqueue(.status(500)) }
            let reporter = makeReporter(uploadMaxAttempts: 3)
            await expectHTTPError(500) { try await reporter.report(self.sampleExecutionReport()) }
            #expect(MockURLProtocol.capturedRequests.count == 3)

        }
    }

    // MARK: heartbeat()

    @Test func heartbeat_succeedsOn200() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(200))
            let reporter = makeReporter()
            try await reporter.heartbeat(sampleActivityPayload())

            let captured = try #require(MockURLProtocol.capturedRequests.first)
            #expect(captured.url?.path == "/api/v1/worker/heartbeat")
            #expect(captured.httpMethod == "POST")

        }
    }

    @Test func heartbeat_retriesOn500_thenSucceeds() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(500))
            MockURLProtocol.enqueue(.status(200))
            let reporter = makeReporter(heartbeatMaxAttempts: 3)
            try await reporter.heartbeat(sampleActivityPayload())
            #expect(MockURLProtocol.capturedRequests.count == 2)

        }
    }

    @Test func heartbeat_sendsActivityPayload() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(200))
            let reporter = makeReporter(workerID: "runner-h")
            let payload = WorkerActivityPayload(
                workerID: "runner-h",
                hostname: "host-1",
                runnerVersion: "test/1.2.3",
                maxConcurrentJobs: 2,
                activeJobs: 1,
                profile: nil
            )
            try await reporter.heartbeat(payload)

            let body = try #require(MockURLProtocol.capturedBodies.first)
            let decoded = try JSONDecoder().decode(WorkerActivityPayload.self, from: body)
            #expect(decoded.workerID == "runner-h")
            #expect(decoded.hostname == "host-1")
            #expect(decoded.runnerVersion == "test/1.2.3")
            #expect(decoded.maxConcurrentJobs == 2)
            #expect(decoded.activeJobs == 1)

        }
    }

    // MARK: Policy separation

    @Test func heartbeat_usesHeartbeatPolicy() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            // Heartbeat policy caps at 2 attempts; upload policy caps at 5. If
            // heartbeat exhausts at 2 the upload policy was not used.
            for _ in 0..<5 { MockURLProtocol.enqueue(.status(500)) }
            let reporter = makeReporter(heartbeatMaxAttempts: 2, uploadMaxAttempts: 5)
            await expectHTTPError(500) { try await reporter.heartbeat(self.sampleActivityPayload()) }
            #expect(MockURLProtocol.capturedRequests.count == 2)

        }
    }

    @Test func report_usesResultUploadPolicy() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            for _ in 0..<5 { MockURLProtocol.enqueue(.status(500)) }
            let reporter = makeReporter(heartbeatMaxAttempts: 5, uploadMaxAttempts: 2)
            await expectHTTPError(500) { try await reporter.report(self.sampleExecutionReport()) }
            #expect(MockURLProtocol.capturedRequests.count == 2)

        }
    }

    // MARK: Misc

    @Test func defaultSession_returnsConfiguredSession() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            let session = Reporter.defaultSession()
            #expect(session.configuration.timeoutIntervalForRequest == 30)
            #expect(session.configuration.timeoutIntervalForResource == 60)

        }
    }

    @Test func errorDescription_coversAllCases() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            let httpDesc = ReporterError.httpError(503, "down").errorDescription
            #expect(httpDesc?.contains("503") ?? false)
            #expect(httpDesc?.contains("down") ?? false)

            #expect(ReporterError.unexpectedResponse.errorDescription != nil)
            #expect(ReporterError.transportError(URLError(.timedOut)).errorDescription != nil)

        }
    }

    // MARK: Helpers

    private func makeReporter(
        workerID: String = "test-worker",
        workerSecret: String = "test-secret",
        heartbeatMaxAttempts: Int = 3,
        uploadMaxAttempts: Int = 3
    ) -> Reporter {
        Reporter(
            apiBaseURL: apiBaseURL,
            workerID: workerID,
            workerSecret: workerSecret,
            heartbeatRetryPolicy: fastPolicy(maxAttempts: heartbeatMaxAttempts),
            resultUploadRetryPolicy: fastPolicy(maxAttempts: uploadMaxAttempts),
            session: .mocked()
        )
    }

    private func fastPolicy(maxAttempts: Int) -> RunnerRetryPolicy {
        RunnerRetryPolicy(
            enabled: true,
            maxAttempts: maxAttempts,
            baseDelayMs: 0,
            maxDelayMs: 0
        )
    }

    private func sampleCollection() -> TestOutcomeCollection {
        TestOutcomeCollection(
            submissionID: "sub_42",
            testSetupID: "ts_1",
            attemptNumber: 1,
            buildStatus: .passed,
            compilerOutput: nil,
            outcomes: [],
            totalTests: 0,
            passCount: 0,
            failCount: 0,
            errorCount: 0,
            timeoutCount: 0,
            executionTimeMs: 0,
            warnings: [],
            jobStartedAt: nil,
            runnerVersion: "shell-runner/1.0",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func sampleExecutionReport() -> WorkerExecutionReport {
        WorkerExecutionReport(collection: sampleCollection(), diagnostics: nil)
    }

    private func sampleActivityPayload() -> WorkerActivityPayload {
        WorkerActivityPayload(
            workerID: "test-worker",
            hostname: "host-x",
            runnerVersion: "test/0.0.1",
            maxConcurrentJobs: 1,
            activeJobs: 0,
            profile: nil
        )
    }

    private func expectHTTPError(
        _ status: Int,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            Issue.record("expected throw")
        } catch let ReporterError.httpError(code, _) {
            #expect(code == status)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
