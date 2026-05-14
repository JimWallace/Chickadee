import Core
import Foundation
import XCTest

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
final class ReporterTests: XCTestCase {

    private let apiBaseURL = URL(string: "https://server.test")!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    // MARK: report() — happy path

    func test_report_succeedsOn200() async throws {
        MockURLProtocol.enqueue(.status(200))
        let reporter = makeReporter()
        try await reporter.report(sampleExecutionReport())
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
    }

    // MARK: report() — wire format

    func test_report_sendsSignedPOST_toResultsEndpoint() async throws {
        MockURLProtocol.enqueue(.status(200))
        let reporter = makeReporter(workerID: "runner-3")
        try await reporter.report(sampleExecutionReport())

        let captured = try XCTUnwrap(MockURLProtocol.capturedRequests.first)
        XCTAssertEqual(captured.url?.path, "/api/v1/worker/results")
        XCTAssertEqual(captured.httpMethod, "POST")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNotNil(captured.value(forHTTPHeaderField: "X-Worker-Signature"))
        XCTAssertNotNil(captured.value(forHTTPHeaderField: "X-Worker-Timestamp"))
        XCTAssertNotNil(captured.value(forHTTPHeaderField: "X-Worker-Nonce"))
        XCTAssertNotNil(captured.value(forHTTPHeaderField: "X-Worker-Body-SHA256"))
        XCTAssertEqual(captured.value(forHTTPHeaderField: "X-Worker-Id"), "runner-3")

        let body = try XCTUnwrap(MockURLProtocol.capturedBodies.first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WorkerExecutionReport.self, from: body)
        XCTAssertEqual(decoded.collection.submissionID, "sub_42")
    }

    func test_report_convenienceOverload_wrapsCollection() async throws {
        MockURLProtocol.enqueue(.status(200))
        let reporter = makeReporter()
        let collection = sampleCollection()
        try await reporter.report(collection)

        let body = try XCTUnwrap(MockURLProtocol.capturedBodies.first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WorkerExecutionReport.self, from: body)
        XCTAssertEqual(decoded.collection.submissionID, collection.submissionID)
        XCTAssertNil(decoded.diagnostics)
    }

    // MARK: report() — retry recovery

    func test_report_retriesOn500_thenSucceeds() async throws {
        MockURLProtocol.enqueue(.status(500))
        MockURLProtocol.enqueue(.status(200))
        let reporter = makeReporter(uploadMaxAttempts: 3)
        try await reporter.report(sampleExecutionReport())
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 2)
    }

    func test_report_retriesOnTransportError_thenSucceeds() async throws {
        MockURLProtocol.enqueue(.failure(URLError(.notConnectedToInternet)))
        MockURLProtocol.enqueue(.status(200))
        let reporter = makeReporter(uploadMaxAttempts: 3)
        try await reporter.report(sampleExecutionReport())
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 2)
    }

    func test_report_retriesOn429() async throws {
        MockURLProtocol.enqueue(.status(429))
        MockURLProtocol.enqueue(.status(200))
        let reporter = makeReporter(uploadMaxAttempts: 3)
        try await reporter.report(sampleExecutionReport())
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 2)
    }

    func test_report_retriesOn503() async throws {
        MockURLProtocol.enqueue(.status(503))
        MockURLProtocol.enqueue(.status(200))
        let reporter = makeReporter(uploadMaxAttempts: 3)
        try await reporter.report(sampleExecutionReport())
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 2)
    }

    func test_report_retriesOn504() async throws {
        MockURLProtocol.enqueue(.status(504))
        MockURLProtocol.enqueue(.status(200))
        let reporter = makeReporter(uploadMaxAttempts: 3)
        try await reporter.report(sampleExecutionReport())
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 2)
    }

    // MARK: report() — terminal classifications

    func test_report_terminatesOn401() async {
        MockURLProtocol.enqueue(.status(401, body: "unauthorized".data(using: .utf8)!))
        let reporter = makeReporter(uploadMaxAttempts: 5)
        await expectHTTPError(401) { try await reporter.report(self.sampleExecutionReport()) }
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
    }

    func test_report_terminatesOn403() async {
        MockURLProtocol.enqueue(.status(403))
        let reporter = makeReporter(uploadMaxAttempts: 5)
        await expectHTTPError(403) { try await reporter.report(self.sampleExecutionReport()) }
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
    }

    func test_report_terminatesOn409() async {
        MockURLProtocol.enqueue(.status(409))
        let reporter = makeReporter(uploadMaxAttempts: 5)
        await expectHTTPError(409) { try await reporter.report(self.sampleExecutionReport()) }
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
    }

    func test_report_terminatesOn400_default() async {
        MockURLProtocol.enqueue(.status(400))
        let reporter = makeReporter(uploadMaxAttempts: 5)
        await expectHTTPError(400) { try await reporter.report(self.sampleExecutionReport()) }
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
    }

    // MARK: report() — retry exhaustion

    func test_report_failsAfterMaxAttempts() async {
        for _ in 0..<5 { MockURLProtocol.enqueue(.status(500)) }
        let reporter = makeReporter(uploadMaxAttempts: 3)
        await expectHTTPError(500) { try await reporter.report(self.sampleExecutionReport()) }
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 3)
    }

    // MARK: heartbeat()

    func test_heartbeat_succeedsOn200() async throws {
        MockURLProtocol.enqueue(.status(200))
        let reporter = makeReporter()
        try await reporter.heartbeat(sampleActivityPayload())

        let captured = try XCTUnwrap(MockURLProtocol.capturedRequests.first)
        XCTAssertEqual(captured.url?.path, "/api/v1/worker/heartbeat")
        XCTAssertEqual(captured.httpMethod, "POST")
    }

    func test_heartbeat_retriesOn500_thenSucceeds() async throws {
        MockURLProtocol.enqueue(.status(500))
        MockURLProtocol.enqueue(.status(200))
        let reporter = makeReporter(heartbeatMaxAttempts: 3)
        try await reporter.heartbeat(sampleActivityPayload())
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 2)
    }

    func test_heartbeat_sendsActivityPayload() async throws {
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

        let body = try XCTUnwrap(MockURLProtocol.capturedBodies.first)
        let decoded = try JSONDecoder().decode(WorkerActivityPayload.self, from: body)
        XCTAssertEqual(decoded.workerID, "runner-h")
        XCTAssertEqual(decoded.hostname, "host-1")
        XCTAssertEqual(decoded.runnerVersion, "test/1.2.3")
        XCTAssertEqual(decoded.maxConcurrentJobs, 2)
        XCTAssertEqual(decoded.activeJobs, 1)
    }

    // MARK: Policy separation

    func test_heartbeat_usesHeartbeatPolicy() async {
        // Heartbeat policy caps at 2 attempts; upload policy caps at 5. If
        // heartbeat exhausts at 2 the upload policy was not used.
        for _ in 0..<5 { MockURLProtocol.enqueue(.status(500)) }
        let reporter = makeReporter(heartbeatMaxAttempts: 2, uploadMaxAttempts: 5)
        await expectHTTPError(500) { try await reporter.heartbeat(self.sampleActivityPayload()) }
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 2)
    }

    func test_report_usesResultUploadPolicy() async {
        for _ in 0..<5 { MockURLProtocol.enqueue(.status(500)) }
        let reporter = makeReporter(heartbeatMaxAttempts: 5, uploadMaxAttempts: 2)
        await expectHTTPError(500) { try await reporter.report(self.sampleExecutionReport()) }
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 2)
    }

    // MARK: Misc

    func test_defaultSession_returnsConfiguredSession() {
        let session = Reporter.defaultSession()
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 60)
    }

    func test_errorDescription_coversAllCases() {
        let httpDesc = ReporterError.httpError(503, "down").errorDescription
        XCTAssertTrue(httpDesc?.contains("503") ?? false)
        XCTAssertTrue(httpDesc?.contains("down") ?? false)

        XCTAssertNotNil(ReporterError.unexpectedResponse.errorDescription)
        XCTAssertNotNil(ReporterError.transportError(URLError(.timedOut)).errorDescription)
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
            XCTFail("expected throw", file: file, line: line)
        } catch let ReporterError.httpError(code, _) {
            XCTAssertEqual(code, status, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }
}
