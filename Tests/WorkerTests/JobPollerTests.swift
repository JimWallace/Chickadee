import Core
import Foundation
import Testing

@testable import chickadee_runner

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Unit tests for `JobPoller`. Network I/O is intercepted via `MockURLProtocol`
/// so every status-code branch and error funnel is exercised without sockets.
///
/// `JobPollerError.unexpectedResponse` is deliberately not covered here — it
/// only fires when `URLSession` returns a non-HTTP `URLResponse`, which the
/// HTTP-only URLProtocol pipeline doesn't produce.
@Suite(.serialized) struct JobPollerTests {

    private let apiBaseURL = URL(string: "https://server.test")!

    // MARK: Status-code branches

    @Test func returnsJob_on200() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
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
            let decoded = try #require(result)
            #expect(decoded.submissionID == "sub_1")
            #expect(decoded.testSetupID == "ts_1")
            #expect(decoded.attemptNumber == 2)
            #expect(decoded.submissionFilename == "main.py")
            #expect(decoded.assignmentSeed == "deadbeef")

        }
    }

    @Test func returnsNil_on204() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(204))
            let poller = makePoller()
            let result = try await poller.requestJob(activeJobs: 0)
            #expect(result == nil)

        }
    }

    @Test func throwsDuplicateWorkerID_on409_withJSONBody() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            let body = #"{"error":"worker already registered"}"#.data(using: .utf8)!
            MockURLProtocol.enqueue(.status(409, body: body))
            let poller = makePoller()

            do {
                _ = try await poller.requestJob(activeJobs: 0)
                Issue.record("expected throw")
            } catch JobPollerError.duplicateWorkerID(let message) {
                #expect(message == "worker already registered")
            } catch {
                Issue.record("unexpected error: \(error)")
            }

        }
    }

    @Test func throwsDuplicateWorkerID_on409_withPlainBody() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            let body = "worker conflict".data(using: .utf8)!
            MockURLProtocol.enqueue(.status(409, body: body))
            let poller = makePoller()

            do {
                _ = try await poller.requestJob(activeJobs: 0)
                Issue.record("expected throw")
            } catch JobPollerError.duplicateWorkerID(let message) {
                #expect(message == "worker conflict")
            } catch {
                Issue.record("unexpected error: \(error)")
            }

        }
    }

    @Test func throwsHTTPError_on500() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            let body = "internal server error".data(using: .utf8)!
            MockURLProtocol.enqueue(.status(500, body: body))
            let poller = makePoller()

            do {
                _ = try await poller.requestJob(activeJobs: 0)
                Issue.record("expected throw")
            } catch JobPollerError.httpError(let code, let returnedBody) {
                #expect(code == 500)
                #expect(returnedBody == "internal server error")
            } catch {
                Issue.record("unexpected error: \(error)")
            }

        }
    }

    @Test func throwsHTTPError_on400() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(400, body: "bad request".data(using: .utf8)!))
            let poller = makePoller()

            do {
                _ = try await poller.requestJob(activeJobs: 0)
                Issue.record("expected throw")
            } catch JobPollerError.httpError(let code, _) {
                #expect(code == 400)
            } catch {
                Issue.record("unexpected error: \(error)")
            }

        }
    }

    // MARK: Error funnels

    @Test func throwsTransportError_onNetworkFailure() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.failure(URLError(.notConnectedToInternet)))
            let poller = makePoller()

            do {
                _ = try await poller.requestJob(activeJobs: 0)
                Issue.record("expected throw")
            } catch JobPollerError.transportError {
                // ok
            } catch {
                Issue.record("unexpected error: \(error)")
            }

        }
    }

    @Test func throwsTransportError_onMalformedJson200() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(200, body: "not json".data(using: .utf8)!))
            let poller = makePoller()

            do {
                _ = try await poller.requestJob(activeJobs: 0)
                Issue.record("expected throw")
            } catch JobPollerError.transportError {
                // ok — Job decode failure is mapped onto transportError per JobPoller.swift:73
            } catch {
                Issue.record("unexpected error: \(error)")
            }

        }
    }

    // MARK: Wire format

    @Test func sendsSignedPOST_withCorrectURL() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(204))
            let poller = makePoller()
            _ = try await poller.requestJob(activeJobs: 0)

            let captured = try #require(MockURLProtocol.capturedRequests.first)
            #expect(captured.url?.path == "/api/v1/worker/request")
            #expect(captured.httpMethod == "POST")
            #expect(captured.value(forHTTPHeaderField: "Content-Type") == "application/json")

        }
    }

    @Test func includesHMACSignatureHeaders() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(204))
            let poller = makePoller(workerID: "runner-7")
            _ = try await poller.requestJob(activeJobs: 0)

            let captured = try #require(MockURLProtocol.capturedRequests.first)
            #expect(captured.value(forHTTPHeaderField: "X-Worker-Signature") != nil)
            #expect(captured.value(forHTTPHeaderField: "X-Worker-Timestamp") != nil)
            #expect(captured.value(forHTTPHeaderField: "X-Worker-Nonce") != nil)
            #expect(captured.value(forHTTPHeaderField: "X-Worker-Body-SHA256") != nil)
            #expect(captured.value(forHTTPHeaderField: "X-Worker-Id") == "runner-7")

        }
    }

    @Test func bodyContainsActivityPayload() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(204))
            let poller = makePoller(workerID: "runner-9", maxConcurrentJobs: 4)
            _ = try await poller.requestJob(activeJobs: 2)

            let body = try #require(MockURLProtocol.capturedBodies.first)
            let payload = try JSONDecoder().decode(WorkerActivityPayload.self, from: body)
            #expect(payload.workerID == "runner-9")
            #expect(payload.maxConcurrentJobs == 4)
            #expect(payload.activeJobs == 2)
            #expect(payload.runnerVersion == ChickadeeVersion.current)
            #expect(payload.profile == nil)

        }
    }

    @Test func includesProfile_whenProvided() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(204))
            let profile = RunnerCapabilityProfile(
                platform: "linux",
                architecture: "x86_64"
            )
            let poller = makePoller(profile: profile)
            _ = try await poller.requestJob(activeJobs: 0)

            let body = try #require(MockURLProtocol.capturedBodies.first)
            let payload = try JSONDecoder().decode(WorkerActivityPayload.self, from: body)
            #expect(payload.profile == profile)

        }
    }

    @Test func omitsProfile_whenNil() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(204))
            let poller = makePoller(profile: nil)
            _ = try await poller.requestJob(activeJobs: 0)

            let body = try #require(MockURLProtocol.capturedBodies.first)
            let payload = try JSONDecoder().decode(WorkerActivityPayload.self, from: body)
            #expect(payload.profile == nil)

        }
    }

    // MARK: Misc

    @Test func defaultSession_returnsConfiguredSession() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            let session = JobPoller.defaultSession()
            #expect(session.configuration.timeoutIntervalForRequest == 30)
            #expect(session.configuration.timeoutIntervalForResource == 60)

        }
    }

    @Test func errorDescription_coversAllCases() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            let httpDesc = JobPollerError.httpError(500, "boom").errorDescription
            #expect(httpDesc != nil)
            #expect(httpDesc?.contains("500") ?? false)
            #expect(httpDesc?.contains("boom") ?? false)

            #expect(JobPollerError.unexpectedResponse.errorDescription != nil)
            #expect(JobPollerError.transportError(URLError(.timedOut)).errorDescription != nil)

            let dupDesc = JobPollerError.duplicateWorkerID("conflict").errorDescription
            #expect(dupDesc?.contains("conflict") ?? false)

        }
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
