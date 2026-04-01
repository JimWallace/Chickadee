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
    func heartbeat(_ payload: WorkerActivityPayload) async throws(ReporterError)
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

        try await sendWithRetry(request)
    }

    func heartbeat(_ payload: WorkerActivityPayload) async throws(ReporterError) {
        let url = apiBaseURL.appendingPathComponent("api/v1/worker/heartbeat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do { request.httpBody = try JSONEncoder().encode(payload) } catch { throw .transportError(error) }
        signer.sign(&request)

        let result = await Self.attemptReport(request: request, expectedStatus: 200)
        switch result {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }

    private func sendWithRetry(_ request: URLRequest) async throws(ReporterError) {
        // Retry up to 3 times with a 5-second pause between attempts so that a
        // transient network blip or server restart doesn't silently discard grades.
        var lastError: ReporterError = .unexpectedResponse
        for attempt in 1...3 {
            let result = await Self.attemptReport(request: request, expectedStatus: 200)
            switch result {
            case .success:
                return
            case .failure(let err):
                lastError = err
                if attempt < 3 {
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
        throw lastError
    }
}

extension Reporter: Reporting {}

private extension Reporter {
    static func attemptReport(request: URLRequest, expectedStatus: Int) async -> Result<Void, ReporterError> {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await Self.session.data(for: request) }
        catch { return .failure(.transportError(error)) }
        guard let http = response as? HTTPURLResponse else { return .failure(.unexpectedResponse) }
        guard http.statusCode == expectedStatus else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            return .failure(.httpError(http.statusCode, body))
        }
        return .success(())
    }
}

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
