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
    func requestJob(activeJobs: Int) async throws(JobPollerError) -> Core.Job?
}

struct JobPoller: Sendable {
    let apiBaseURL: URL
    let workerID: String
    let maxConcurrentJobs: Int
    let profile: RunnerCapabilityProfile?
    private let signer: WorkerRequestSigner

    init(
        apiBaseURL: URL,
        workerID: String,
        workerSecret: String,
        maxConcurrentJobs: Int,
        profile: RunnerCapabilityProfile? = nil
    ) {
        self.apiBaseURL        = apiBaseURL
        self.workerID          = workerID
        self.maxConcurrentJobs = maxConcurrentJobs
        self.profile           = profile
        self.signer            = WorkerRequestSigner(sharedSecret: workerSecret, workerID: workerID)
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 30
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    /// POST /api/v1/worker/request → Job, or nil when no work is available.
    func requestJob(activeJobs: Int) async throws(JobPollerError) -> Core.Job? {
        let url = apiBaseURL.appendingPathComponent("api/v1/worker/request")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = WorkerActivityPayload(
            workerID: workerID,
            hostname: ProcessInfo.processInfo.hostName,
            runnerVersion: ChickadeeVersion.current,
            maxConcurrentJobs: maxConcurrentJobs,
            activeJobs: activeJobs,
            profile: profile
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
        case 409:
            struct ServerError: Decodable { let error: String }
            let msg = (try? JSONDecoder().decode(ServerError.self, from: data))?.error
                   ?? String(data: data, encoding: .utf8)
                   ?? "duplicate worker ID"
            throw .duplicateWorkerID(msg)
        default:
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw .httpError(http.statusCode, body)
        }
    }
}

extension JobPoller: JobPolling {}

enum JobPollerError: Error, LocalizedError {
    case unexpectedResponse
    case httpError(Int, String)
    case transportError(any Error)
    case duplicateWorkerID(String)

    var errorDescription: String? {
        switch self {
        case .unexpectedResponse:
            return "Non-HTTP response from API server"
        case .httpError(let code, let body):
            return "API server returned HTTP \(code): \(body)"
        case .transportError(let error):
            return "Transport error: \(error.localizedDescription)"
        case .duplicateWorkerID(let message):
            return "Duplicate worker ID: \(message)"
        }
    }
}
