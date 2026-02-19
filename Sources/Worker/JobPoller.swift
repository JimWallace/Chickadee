// Worker/JobPoller.swift
//
// Contacts the API server to claim the next pending job.
// Returns nil (204) when there is nothing to do.

import Foundation
import Core

struct JobPoller: Sendable {
    let apiBaseURL: URL
    let workerID: String

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 30
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    /// POST /api/v1/worker/request → Job, or nil when no work is available.
    func requestJob() async throws -> Core.Job? {
        let url     = apiBaseURL.appendingPathComponent("api/v1/worker/request")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = WorkerRequestPayload(
            workerID: workerID,
            hostname: ProcessInfo.processInfo.hostName
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await Self.session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw JobPollerError.unexpectedResponse
        }

        switch http.statusCode {
        case 200:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Core.Job.self, from: data)
        case 204:
            return nil
        default:
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw JobPollerError.httpError(http.statusCode, body)
        }
    }
}

// MARK: - Helpers

private struct WorkerRequestPayload: Encodable {
    let workerID: String
    let hostname: String
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
