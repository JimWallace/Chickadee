// Worker/Reporter.swift
//
// Posts a completed TestOutcomeCollection back to the API server.

import Foundation
import Core

struct Reporter: Sendable {
    let apiBaseURL: URL
    let workerID: String
    let workerSecret: String

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 30
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    func report(_ collection: TestOutcomeCollection) async throws {
        let url     = apiBaseURL.appendingPathComponent("api/v1/worker/results")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !workerSecret.isEmpty {
            request.setValue(workerSecret, forHTTPHeaderField: "X-Worker-Secret")
            request.setValue(workerID, forHTTPHeaderField: "X-Worker-Id")
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(collection)

        let (data, response) = try await Self.session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ReporterError.unexpectedResponse
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw ReporterError.httpError(http.statusCode, body)
        }
    }
}

enum ReporterError: Error, LocalizedError {
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
