// Worker/Reporter.swift
//
// Posts a completed TestOutcomeCollection back to the API server.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession, URLRequest on Linux
#endif
import Core
import Crypto

protocol Reporting: Sendable {
    func report(_ collection: TestOutcomeCollection) async throws
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

    func report(_ collection: TestOutcomeCollection) async throws {
        let url = apiBaseURL.appendingPathComponent("api/v1/worker/results")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(collection)
        signer.sign(&request)
        logSignedRequest("report", request: request)

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

extension Reporter: Reporting {}

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

private extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
