import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Core
@testable import chickadee_runner

/// Unit tests for `JobPoller`. Network I/O is intercepted via `MockURLProtocol`
/// so every status-code branch and error funnel is exercised without sockets.
///
/// `JobPollerError.unexpectedResponse` is deliberately not covered here — it
/// only fires when `URLSession` returns a non-HTTP `URLResponse`, which the
/// HTTP-only URLProtocol pipeline doesn't produce.
final class JobPollerTests: XCTestCase {

    private let apiBaseURL = URL(string: "https://server.test")!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    // MARK: Status-code branches

    func test_returnsJob_on200() async throws {
        let manifest = TestProperties()
        let job = Job(
            submissionID: "sub_1",
            testSetupID: "ts_1",
            attemptNumber: 2,
            submissionURL: URL(string: "https://server.test/sub.zip")!,
            testSetupURL: URL(string: "https://server.test/ts.zip")!,
            manifest: manifest,
            submissionFilename: "main.py",
            assignmentSeed: "deadbeef"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(job)
        MockURLProtocol.enqueue(.status(200, body: body))

        let poller = makePoller()
        let result = try await poller.requestJob(activeJobs: 0)
        let decoded = try XCTUnwrap(result)
        XCTAssertEqual(decoded.submissionID, "sub_1")
        XCTAssertEqual(decoded.testSetupID, "ts_1")
        XCTAssertEqual(decoded.attemptNumber, 2)
        XCTAssertEqual(decoded.submissionFilename, "main.py")
        XCTAssertEqual(decoded.assignmentSeed, "deadbeef")
    }

    func test_returnsNil_on204() async throws {
        MockURLProtocol.enqueue(.status(204))
        let poller = makePoller()
        let result = try await poller.requestJob(activeJobs: 0)
        XCTAssertNil(result)
    }

    func test_throwsDuplicateWorkerID_on409_withJSONBody() async {
        let body = #"{"error":"worker already registered"}"#.data(using: .utf8)!
        MockURLProtocol.enqueue(.status(409, body: body))
        let poller = makePoller()

        do {
            _ = try await poller.requestJob(activeJobs: 0)
            XCTFail("expected throw")
        } catch JobPollerError.duplicateWorkerID(let message) {
            XCTAssertEqual(message, "worker already registered")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_throwsDuplicateWorkerID_on409_withPlainBody() async {
        let body = "worker conflict".data(using: .utf8)!
        MockURLProtocol.enqueue(.status(409, body: body))
        let poller = makePoller()

        do {
            _ = try await poller.requestJob(activeJobs: 0)
            XCTFail("expected throw")
        } catch JobPollerError.duplicateWorkerID(let message) {
            XCTAssertEqual(message, "worker conflict")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_throwsHTTPError_on500() async {
        let body = "internal server error".data(using: .utf8)!
        MockURLProtocol.enqueue(.status(500, body: body))
        let poller = makePoller()

        do {
            _ = try await poller.requestJob(activeJobs: 0)
            XCTFail("expected throw")
        } catch JobPollerError.httpError(let code, let returnedBody) {
            XCTAssertEqual(code, 500)
            XCTAssertEqual(returnedBody, "internal server error")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_throwsHTTPError_on400() async {
        MockURLProtocol.enqueue(.status(400, body: "bad request".data(using: .utf8)!))
        let poller = makePoller()

        do {
            _ = try await poller.requestJob(activeJobs: 0)
            XCTFail("expected throw")
        } catch JobPollerError.httpError(let code, _) {
            XCTAssertEqual(code, 400)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: Error funnels

    func test_throwsTransportError_onNetworkFailure() async {
        MockURLProtocol.enqueue(.failure(URLError(.notConnectedToInternet)))
        let poller = makePoller()

        do {
            _ = try await poller.requestJob(activeJobs: 0)
            XCTFail("expected throw")
        } catch JobPollerError.transportError {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_throwsTransportError_onMalformedJson200() async {
        MockURLProtocol.enqueue(.status(200, body: "not json".data(using: .utf8)!))
        let poller = makePoller()

        do {
            _ = try await poller.requestJob(activeJobs: 0)
            XCTFail("expected throw")
        } catch JobPollerError.transportError {
            // ok — Job decode failure is mapped onto transportError per JobPoller.swift:73
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: Wire format

    func test_sendsSignedPOST_withCorrectURL() async throws {
        MockURLProtocol.enqueue(.status(204))
        let poller = makePoller()
        _ = try await poller.requestJob(activeJobs: 0)

        let captured = try XCTUnwrap(MockURLProtocol.capturedRequests.first)
        XCTAssertEqual(captured.url?.path, "/api/v1/worker/request")
        XCTAssertEqual(captured.httpMethod, "POST")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func test_includesHMACSignatureHeaders() async throws {
        MockURLProtocol.enqueue(.status(204))
        let poller = makePoller(workerID: "runner-7")
        _ = try await poller.requestJob(activeJobs: 0)

        let captured = try XCTUnwrap(MockURLProtocol.capturedRequests.first)
        XCTAssertNotNil(captured.value(forHTTPHeaderField: "X-Worker-Signature"))
        XCTAssertNotNil(captured.value(forHTTPHeaderField: "X-Worker-Timestamp"))
        XCTAssertNotNil(captured.value(forHTTPHeaderField: "X-Worker-Nonce"))
        XCTAssertNotNil(captured.value(forHTTPHeaderField: "X-Worker-Body-SHA256"))
        XCTAssertEqual(captured.value(forHTTPHeaderField: "X-Worker-Id"), "runner-7")
    }

    func test_bodyContainsActivityPayload() async throws {
        MockURLProtocol.enqueue(.status(204))
        let poller = makePoller(workerID: "runner-9", maxConcurrentJobs: 4)
        _ = try await poller.requestJob(activeJobs: 2)

        let body = try XCTUnwrap(MockURLProtocol.capturedBodies.first)
        let payload = try JSONDecoder().decode(WorkerActivityPayload.self, from: body)
        XCTAssertEqual(payload.workerID, "runner-9")
        XCTAssertEqual(payload.maxConcurrentJobs, 4)
        XCTAssertEqual(payload.activeJobs, 2)
        XCTAssertEqual(payload.runnerVersion, ChickadeeVersion.current)
        XCTAssertNil(payload.profile)
    }

    func test_includesProfile_whenProvided() async throws {
        MockURLProtocol.enqueue(.status(204))
        let profile = RunnerCapabilityProfile(
            platform: "linux",
            architecture: "x86_64"
        )
        let poller = makePoller(profile: profile)
        _ = try await poller.requestJob(activeJobs: 0)

        let body = try XCTUnwrap(MockURLProtocol.capturedBodies.first)
        let payload = try JSONDecoder().decode(WorkerActivityPayload.self, from: body)
        XCTAssertEqual(payload.profile, profile)
    }

    func test_omitsProfile_whenNil() async throws {
        MockURLProtocol.enqueue(.status(204))
        let poller = makePoller(profile: nil)
        _ = try await poller.requestJob(activeJobs: 0)

        let body = try XCTUnwrap(MockURLProtocol.capturedBodies.first)
        let payload = try JSONDecoder().decode(WorkerActivityPayload.self, from: body)
        XCTAssertNil(payload.profile)
    }

    // MARK: Misc

    func test_defaultSession_returnsConfiguredSession() {
        let session = JobPoller.defaultSession()
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 60)
    }

    func test_errorDescription_coversAllCases() {
        let httpDesc = JobPollerError.httpError(500, "boom").errorDescription
        XCTAssertNotNil(httpDesc)
        XCTAssertTrue(httpDesc?.contains("500") ?? false)
        XCTAssertTrue(httpDesc?.contains("boom") ?? false)

        XCTAssertNotNil(JobPollerError.unexpectedResponse.errorDescription)
        XCTAssertNotNil(JobPollerError.transportError(URLError(.timedOut)).errorDescription)

        let dupDesc = JobPollerError.duplicateWorkerID("conflict").errorDescription
        XCTAssertTrue(dupDesc?.contains("conflict") ?? false)
    }

    // MARK: Helpers

    private func makePoller(
        workerID: String = "test-worker",
        workerSecret: String = "test-secret",
        maxConcurrentJobs: Int = 1,
        profile: RunnerCapabilityProfile? = nil
    ) -> JobPoller {
        JobPoller(
            apiBaseURL: apiBaseURL,
            workerID: workerID,
            workerSecret: workerSecret,
            maxConcurrentJobs: maxConcurrentJobs,
            profile: profile,
            session: .mocked()
        )
    }
}
