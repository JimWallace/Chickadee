// Worker/Reporter.swift
//
// Posts a completed TestOutcomeCollection back to the API server.

import Core
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession, URLRequest on Linux
#endif

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
        self.workerID = workerID
        self.signer = WorkerRequestSigner(sharedSecret: workerSecret, workerID: workerID)
        self.heartbeatRetryPolicy = heartbeatRetryPolicy
        self.resultUploadRetryPolicy = resultUploadRetryPolicy
        self.session = session
    }

    static func defaultSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }

    func report(_ report: WorkerExecutionReport) async throws(ReporterError) {
        let url = apiBaseURL.appendingPathComponent("api/v1/worker/results")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Total-size budget (#1157): per-stream capture is already capped at
        // 1 MB, but a many-test suite with verbose failures could exceed the
        // server's ingest limit and the whole report was rejected — the
        // submission never resolved. Truncate longResults across the
        // collection instead (statuses and aggregates untouched); the
        // collection carries a visible warning when anything was cut.
        //
        // The report is encoded first. The collection's JSON is part of the
        // report's JSON, so a report within the budget holds a collection
        // within it, which the truncation would return unchanged: its body is
        // these bytes, and the collection is not encoded a second time just
        // to be measured.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            var body = try encoder.encode(report)
            if body.count > TestOutcomeCollection.defaultSerializedBudgetBytes {
                let (bounded, didTruncate) = report.collection.truncatingOversizedOutput()
                if didTruncate {
                    body = try encoder.encode(
                        WorkerExecutionReport(
                            collection: bounded, diagnostics: report.diagnostics, matches: report.matches))
                }
            }
            request.httpBody = body
        } catch {
            throw .transportError(error)
        }

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

        try await sendWithRetry(
            request,
            stage: .heartbeat,
            policy: heartbeatRetryPolicy
        )
    }

    /// Sends `request`, signed afresh on every attempt: the server records each
    /// nonce and refuses a second use as a replay, and refuses a timestamp
    /// older than its skew window, so a retry of the first signature would
    /// fail with 401 and end the retries (#2270).
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
                    case .claimSuperseded:
                        return .terminal("claim superseded")
                    }
                },
                onRetry: { context in
                    let event = context.stage == .heartbeat ? "heartbeat_retry_scheduled" : "network_retry_scheduled"
                    writeStructuredRunnerLog(
                        event: event,
                        fields: [
                            "runner_id": workerID,
                            "failure_stage": context.stage.rawValue,
                            "attempt": context.attempt,
                            "max_attempts": context.maxAttempts,
                            "retry_in_seconds": context.retryInSeconds ?? 0,
                            "retryable": context.retryable,
                            "error_message_summary": context.message,
                        ])
                },
                operation: {
                    var signed = request
                    signer.sign(&signed)
                    let result = await Self.attemptReport(session: session, request: signed, expectedStatus: 200)
                    switch result {
                    case .success:
                        return ()
                    case .failure(let error):
                        throw error
                    }
                }
            )
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
    static func attemptReport(
        session: URLSession, request: URLRequest, expectedStatus: Int
    ) async -> Result<Void, ReporterError> {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { return .failure(.transportError(error)) }
        guard let http = response as? HTTPURLResponse else { return .failure(.unexpectedResponse) }
        guard http.statusCode == expectedStatus else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            // 410: the server no longer counts this job as ours (a forced
            // retest or the stuck-submission reaper re-queued it). Terminal,
            // and the caller drops the job rather than reporting a failure.
            if http.statusCode == 410 { return .failure(.claimSuperseded(body)) }
            return .failure(.httpError(http.statusCode, body))
        }
        return .success(())
    }
}

enum ReporterError: Error, LocalizedError {
    case unexpectedResponse
    case httpError(Int, String)
    case transportError(any Error)
    /// The server refused a result report (HTTP 410) because the job's claim
    /// is no longer current: the submission was re-queued after this runner
    /// claimed it. The report is dropped, not retried, and no failure is
    /// reported for the job.
    case claimSuperseded(String)

    var errorDescription: String? {
        switch self {
        case .unexpectedResponse:
            return "Non-HTTP response from API server"
        case .httpError(let code, let body):
            return "API server returned HTTP \(code): \(body)"
        case .transportError(let error):
            return "Transport error: \(error.localizedDescription)"
        case .claimSuperseded(let body):
            return "API server refused the result: the claim is no longer current: \(body)"
        }
    }
}
