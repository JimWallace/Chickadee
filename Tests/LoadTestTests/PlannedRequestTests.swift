import Core
import Foundation
import Testing

@testable import chickadee_loadtest

@Suite struct PlannedRequestTests {
    private let target: LoadTarget

    init() throws {
        target = try LoadTarget(baseURL: "http://localhost:8080", allowRemote: false)
    }

    /// The server must accept the poll, or the test measures only the
    /// 401 path. Verify with the server's own check.
    @Test func runnerPollCarriesASignatureTheServerAccepts() throws {
        let request = try PlannedRequest.runnerPoll(
            target: target, workerID: "loadtest-runner-3", secret: "s3cret")
        let headers = Dictionary(uniqueKeysWithValues: request.headers.map { ($0.name, $0.value) })
        let body = try #require(request.body)

        let signed = WorkerHMACSigning.SignedHeaders(
            timestamp: try #require(headers[WorkerHMACSigning.Header.timestamp]),
            nonce: try #require(headers[WorkerHMACSigning.Header.nonce]),
            bodyHash: try #require(headers[WorkerHMACSigning.Header.bodyHash]),
            signature: try #require(headers[WorkerHMACSigning.Header.signature]),
            workerID: headers[WorkerHMACSigning.Header.workerID]
        )
        #expect(request.method == "POST")
        #expect(request.url == "http://localhost:8080/api/v1/worker/request")
        #expect(signed.workerID == "loadtest-runner-3")
        #expect(signed.bodyHash == sha256HexDigest(body))
        #expect(
            WorkerHMACSigning.verify(
                method: "POST", path: "/api/v1/worker/request", headers: signed, secret: "s3cret"))
        #expect(
            !WorkerHMACSigning.verify(
                method: "POST", path: "/api/v1/worker/request", headers: signed, secret: "other"))

        let payload = try JSONDecoder().decode(WorkerActivityPayload.self, from: body)
        #expect(payload.workerID == "loadtest-runner-3")
        #expect(payload.activeJobs == 0)
    }

    /// The server refuses a reused nonce, so each poll needs its own.
    @Test func eachRunnerPollHasAFreshNonce() throws {
        let first = try PlannedRequest.runnerPoll(target: target, workerID: "r", secret: "s")
        let second = try PlannedRequest.runnerPoll(target: target, workerID: "r", secret: "s")
        let nonce = { (request: PlannedRequest) in
            request.headers.first { $0.name == WorkerHMACSigning.Header.nonce }?.value
        }
        #expect(nonce(first) != nil)
        #expect(nonce(first) != nonce(second))
    }

    @Test func statusPollSendsTheSessionCookie() {
        let request = PlannedRequest.statusPoll(
            target: target, submissionID: "sub_42", sessionCookie: "vapor-session=abc")
        #expect(request.method == "GET")
        #expect(request.url == "http://localhost:8080/api/v1/submissions/sub_42")
        #expect(request.body == nil)
        #expect(request.headers.contains { $0.name == "Cookie" && $0.value == "vapor-session=abc" })
    }
}
