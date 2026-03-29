// Worker/Reporter.swift
//
// Posts a completed TestOutcomeCollection back to the API server.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession, URLRequest on Linux
#endif
import Core

protocol Reporting: Sendable {
    func report(_ collection: TestOutcomeCollection) async throws(ReporterError)
}

struct Reporter: Sendable {
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

    func report(_ collection: TestOutcomeCollection) async throws(ReporterError) {
        let url = apiBaseURL.appendingPathComponent("api/v1/worker/results")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do { request.httpBody = try encoder.encode(collection) } catch { throw .transportError(error) }
        signer.sign(&request)

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await Self.session.data(for: request) } catch { throw .transportError(error) }

        guard let http = response as? HTTPURLResponse else {
            throw .unexpectedResponse
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw .httpError(http.statusCode, body)
        }
    }
}

extension Reporter: Reporting {}

enum ReporterError: Error, LocalizedError {
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
