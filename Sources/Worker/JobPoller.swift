// Worker/JobPoller.swift
//
// Contacts the API server to claim the next pending job.
// Returns nil (204) when there is nothing to do.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession, URLRequest on Linux
#endif
import Core

protocol JobPolling: Sendable {
    func requestJob() async throws(JobPollerError) -> Core.Job?
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
    func requestJob() async throws(JobPollerError) -> Core.Job? {
        let url = apiBaseURL.appendingPathComponent("api/v1/worker/request")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = WorkerRequestPayload(
            workerID: workerID,
            hostname: ProcessInfo.processInfo.hostName
        )
        do { request.httpBody = try JSONEncoder().encode(payload) } catch { throw .transportError(error) }
        signer.sign(&request)

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await Self.session.data(for: request) } catch { throw .transportError(error) }

        guard let http = response as? HTTPURLResponse else {
            throw .unexpectedResponse
        }

        switch http.statusCode {
        case 200:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do { return try decoder.decode(Core.Job.self, from: data) } catch { throw .transportError(error) }
        case 204:
            return nil
        default:
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw .httpError(http.statusCode, body)
        }
    }
}

extension JobPoller: JobPolling {}

// MARK: - Helpers

private struct WorkerRequestPayload: Encodable {
    let workerID: String
    let hostname: String
}

enum JobPollerError: Error, LocalizedError {
    case unexpectedResponse
    case httpError(Int, String)
    case transportError(any Error)

    var errorDescription: String? {
        switch self {
        case .unexpectedResponse:
            return "Non-HTTP response from API server"
        case .httpError(let code, let body):
            return "API server returned HTTP \(code): \(body)"
        case .transportError(let error):
            return "Transport error: \(error.localizedDescription)"
        }
    }
}
