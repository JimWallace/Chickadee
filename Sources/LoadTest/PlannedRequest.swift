// LoadTest/PlannedRequest.swift
//
// Builds each request as plain data, so the tests can check the signature
// and the headers without a network client.

import Core
import Foundation

struct PlannedRequest: Sendable {
    let method: String
    let url: String
    let headers: [(name: String, value: String)]
    let body: Data?

    /// A signed runner poll. The runner sends the same payload and headers
    /// (`JobPoller`, `WorkerRequestSigner`), so the server does the same work
    /// for it: the HMAC check, the nonce insert, the check-in and the
    /// pending-work query.
    static func runnerPoll(
        target: LoadTarget,
        workerID: String,
        secret: String,
        now: Date = Date()
    ) throws -> PlannedRequest {
        let path = "/api/v1/worker/request"
        let payload = WorkerActivityPayload(
            workerID: workerID,
            hostname: "chickadee-loadtest",
            runnerVersion: ChickadeeVersion.current,
            maxConcurrentJobs: 1,
            activeJobs: 0
        )
        let body = try JSONEncoder().encode(payload)
        let signed = WorkerHMACSigning.signedHeaders(
            method: "POST",
            path: path,
            body: body,
            secret: secret,
            workerID: workerID,
            timestamp: Int64(now.timeIntervalSince1970)
        )
        var headers: [(name: String, value: String)] = [
            ("Content-Type", "application/json"),
            (WorkerHMACSigning.Header.timestamp, signed.timestamp),
            (WorkerHMACSigning.Header.nonce, signed.nonce),
            (WorkerHMACSigning.Header.bodyHash, signed.bodyHash),
            (WorkerHMACSigning.Header.signature, signed.signature),
        ]
        if let signedWorkerID = signed.workerID {
            headers.append((WorkerHMACSigning.Header.workerID, signedWorkerID))
        }
        return PlannedRequest(method: "POST", url: target.url(forPath: path), headers: headers, body: body)
    }

    /// A result-view status poll, sent with a signed-in session cookie.
    static func statusPoll(target: LoadTarget, submissionID: String, sessionCookie: String) -> PlannedRequest {
        let encodedID =
            submissionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? submissionID
        return PlannedRequest(
            method: "GET",
            url: target.url(forPath: "/api/v1/submissions/\(encodedID)"),
            headers: [("Accept", "application/json"), ("Cookie", sessionCookie)],
            body: nil
        )
    }
}
