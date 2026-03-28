// Worker/JobPoller.swift
//
// Contacts the API server to claim the next pending job.
// Returns nil (204) when there is nothing to do.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession, URLRequest on Linux
#endif
import Core
import Crypto

protocol JobPolling: Sendable {
    func requestJob() async throws -> Core.Job?
}

struct JobPoller: Sendable {
    let apiBaseURL: URL
    let workerID: String
    private let signer: WorkerRequestSigner

    init(apiBaseURL: URL, workerID: String, workerSecret: String) {
        self.apiBaseURL = apiBaseURL
        self.workerID   = workerID
        self.signer     = WorkerRequestSigner(sharedSecret: workerSecret, workerID: workerID)
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 30
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    /// POST /api/v1/worker/request → Job, or nil when no work is available.
    func requestJob() async throws -> Core.Job? {
        let url = apiBaseURL.appendingPathComponent("api/v1/worker/request")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = WorkerRequestPayload(
            workerID: workerID,
            hostname: ProcessInfo.processInfo.hostName
        )
        request.httpBody = try JSONEncoder().encode(body)
        signer.sign(&request)
        logSignedRequest("claim", request: request)

        let (data, response) = try await Self.session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw JobPollerError.unexpectedResponse
        }

        switch http.statusCode {
        case 200:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let job = try decoder.decode(Core.Job.self, from: data)
            fputs("[\(workerID)] Claimed job \(job.submissionID) submissionURL=\(job.submissionURL.absoluteString) testSetupURL=\(job.testSetupURL.absoluteString)\n", stderr)
            return job
        case 204:
            return nil
        default:
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw JobPollerError.httpError(http.statusCode, body)
        }
    }
}

extension JobPoller: JobPolling {}

// MARK: - Helpers

private struct WorkerRequestPayload: Encodable {
    let workerID: String
    let hostname: String
}

private func logSignedRequest(_ label: String, request: URLRequest) {
    let method = (request.httpMethod ?? "GET").uppercased()
    let path = request.url?.path ?? "/"
    let host = request.url?.host ?? "<nil>"
    let scheme = request.url?.scheme ?? "<nil>"
    let timestamp = request.value(forHTTPHeaderField: "X-Worker-Timestamp") ?? "<missing>"
    let nonce = request.value(forHTTPHeaderField: "X-Worker-Nonce") ?? "<missing>"
    let signature = request.value(forHTTPHeaderField: "X-Worker-Signature") ?? "<missing>"
    let bodyHash = sha256Hex(request.httpBody.map(Array.init) ?? [])
    fputs("[worker-http] \(label) \(method) \(scheme)://\(host)\(path) bodyHash=\(bodyHash) ts=\(timestamp) nonce=\(nonce) sigPrefix=\(String(signature.prefix(12)))\n", stderr)
}

private func sha256Hex(_ bytes: [UInt8]) -> String {
    Data(SHA256.hash(data: Data(bytes))).hexEncodedString()
}

enum JobPollerError: Error, LocalizedError {
    case unexpectedResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .unexpectedResponse:
            return "Non-HTTP response from API server"
        case .httpError(let code, let body):
            return "API server returned HTTP \(code): \(body)"
        }
    }
}

private extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
