// Worker/Reporter.swift
//
// Posts a completed TestOutcomeCollection back to the API server.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession, URLRequest on Linux
#endif
import Core

protocol Reporting: Sendable {
    func report(_ report: WorkerExecutionReport) async throws(ReporterError)
    func heartbeat(_ payload: WorkerActivityPayload) async throws(ReporterError)
}

struct Reporter: Sendable {
    let apiBaseURL: URL
    let workerID: String
    private let signer: WorkerRequestSigner
    private let heartbeatRetryPolicy: RunnerRetryPolicy
    private let resultUploadRetryPolicy: RunnerRetryPolicy
    private let session: URLSession

    init(
        apiBaseURL: URL,
        workerID: String,
        workerSecret: String,
        heartbeatRetryPolicy: RunnerRetryPolicy = .heartbeat(),
        resultUploadRetryPolicy: RunnerRetryPolicy = .resultUpload(),
        session: URLSession = Reporter.defaultSession()
    ) {
        self.apiBaseURL = apiBaseURL
        self.workerID   = workerID
        self.signer     = WorkerRequestSigner(sharedSecret: workerSecret, workerID: workerID)
        self.heartbeatRetryPolicy = heartbeatRetryPolicy
        self.resultUploadRetryPolicy = resultUploadRetryPolicy
        self.session = session
    }

    static func defaultSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 30
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }

    func report(_ report: WorkerExecutionReport) async throws(ReporterError) {
        let url = apiBaseURL.appendingPathComponent("api/v1/worker/results")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do { request.httpBody = try encoder.encode(report) } catch { throw .transportError(error) }
        signer.sign(&request)

        try await sendWithRetry(
            request,
            stage: .resultUpload,
            policy: resultUploadRetryPolicy
        )
    }

    func heartbeat(_ payload: WorkerActivityPayload) async throws(ReporterError) {
        let url = apiBaseURL.appendingPathComponent("api/v1/worker/heartbeat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do { request.httpBody = try JSONEncoder().encode(payload) } catch { throw .transportError(error) }
        signer.sign(&request)

        try await sendWithRetry(
            request,
            stage: .heartbeat,
            policy: heartbeatRetryPolicy
        )
    }

    private func sendWithRetry(
        _ request: URLRequest,
        stage: RunnerRetryStage,
        policy: RunnerRetryPolicy
    ) async throws(ReporterError) {
        do {
            try await withRunnerRetry(
            stage: stage,
            policy: policy,
            shouldRetry: { error in
                guard let reporterError = error as? ReporterError else {
                    return .terminal(String(describing: error))
                }
                switch reporterError {
                case .transportError(let underlying):
                    return .retryable(underlying.localizedDescription)
                case .httpError(let statusCode, let body):
                    return classifyHTTPRetry(statusCode: statusCode, body: body)
                case .unexpectedResponse:
                    return .terminal("unexpected response")
                }
            },
            onRetry: { context in
                let event = context.stage == .heartbeat ? "heartbeat_retry_scheduled" : "network_retry_scheduled"
                writeStructuredRunnerLog(event: event, fields: [
                    "runner_id": self.workerID,
                    "failure_stage": context.stage.rawValue,
                    "attempt": context.attempt,
                    "max_attempts": context.maxAttempts,
                    "retry_in_seconds": context.retryInSeconds ?? 0,
                    "retryable": context.retryable,
                    "error_message_summary": context.message,
                ])
            }
        ) {
            let result = await Self.attemptReport(session: session, request: request, expectedStatus: 200)
            switch result {
            case .success:
                return ()
            case .failure(let error):
                throw error
            }
        }
        } catch let reporterError as ReporterError {
            throw reporterError
        } catch {
            throw .transportError(error)
        }
    }
}

extension Reporter: Reporting {}

extension Reporting {
    func report(_ collection: TestOutcomeCollection) async throws(ReporterError) {
        try await report(WorkerExecutionReport(collection: collection, diagnostics: nil))
    }
}

private extension Reporter {
    static func attemptReport(session: URLSession, request: URLRequest, expectedStatus: Int) async -> Result<Void, ReporterError> {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
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
