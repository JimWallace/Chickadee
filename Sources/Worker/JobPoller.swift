// Worker/JobPoller.swift
//
// Contacts the API server to claim the next pending job.
// Returns nil (204) when there is nothing to do.

import Core
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession, URLRequest on Linux
#endif

protocol JobPolling: Sendable {
    func requestJob(activeJobs: Int) async throws(JobPollerError) -> Core.Job?
    /// One poll of the daemon's loop. A poller that cannot ask the server to
    /// hold the poll takes the default, which never reports a held poll.
    func pollForJob(activeJobs: Int) async throws(JobPollerError) -> JobPollResult
}

extension JobPolling {
    func pollForJob(activeJobs: Int) async throws(JobPollerError) -> JobPollResult {
        JobPollResult(job: try await requestJob(activeJobs: activeJobs), serverHeldPoll: false)
    }
}

/// What one poll returned.
struct JobPollResult: Sendable {
    /// The claimed job, or nil when the server had none for this runner.
    let job: Core.Job?
    /// True when the server held an empty poll open (`WorkerLongPoll`). The
    /// server has already waited, so the slot polls again at once.
    let serverHeldPoll: Bool
}

struct JobPoller: Sendable {
    let apiBaseURL: URL
    let workerID: String
    let maxConcurrentJobs: Int
    let profile: RunnerCapabilityProfile?
    /// A 204 that took less than this was not held, whatever its header says
    /// (a server shutting down releases its held polls at once), so the slot
    /// backs off as it does for any empty poll.
    let minimumHeldDuration: Duration
    private let signer: WorkerRequestSigner
    private let session: URLSession

    init(
        apiBaseURL: URL,
        workerID: String,
        workerSecret: String,
        maxConcurrentJobs: Int,
        profile: RunnerCapabilityProfile? = nil,
        session: URLSession = JobPoller.defaultSession(),
        minimumHeldDuration: Duration = .seconds(1)
    ) {
        self.apiBaseURL = apiBaseURL
        self.workerID = workerID
        self.maxConcurrentJobs = maxConcurrentJobs
        self.profile = profile
        self.signer = WorkerRequestSigner(sharedSecret: workerSecret, workerID: workerID)
        self.session = session
        self.minimumHeldDuration = minimumHeldDuration
    }

    static func defaultSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }

    /// POST /api/v1/worker/request → Job, or nil when no work is available.
    /// Asks for an immediate answer.
    func requestJob(activeJobs: Int) async throws(JobPollerError) -> Core.Job? {
        try await poll(activeJobs: activeJobs, longPollSeconds: nil).job
    }

    /// The daemon's poll: asks the server to hold the poll open while it has
    /// no job for this runner (`WorkerLongPoll`).
    func pollForJob(activeJobs: Int) async throws(JobPollerError) -> JobPollResult {
        try await poll(activeJobs: activeJobs, longPollSeconds: WorkerLongPoll.requestedHoldSeconds)
    }

    private func poll(activeJobs: Int, longPollSeconds: Int?) async throws(JobPollerError) -> JobPollResult {
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
            profile: profile,
            longPollSeconds: longPollSeconds
        )
        do { request.httpBody = try JSONEncoder().encode(payload) } catch { throw .transportError(error) }
        signer.sign(&request)

        let clock = ContinuousClock()
        let started = clock.now
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch { throw .transportError(error) }
        let elapsed = clock.now - started

        guard let http = response as? HTTPURLResponse else {
            throw .unexpectedResponse
        }

        switch http.statusCode {
        case 200:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            // A decode failure is a server/worker schema mismatch, not a network
            // problem — classify it distinctly so ops doesn't chase a transport
            // issue that doesn't exist (June 2026 audit, P2.5). Still retryable:
            // the mismatch usually resolves when the other side is upgraded.
            do {
                return JobPollResult(job: try decoder.decode(Core.Job.self, from: data), serverHeldPoll: false)
            } catch {
                throw .decodingFailed(error)
            }
        case 204:
            let held =
                longPollSeconds != nil
                && http.value(forHTTPHeaderField: WorkerLongPoll.heldHeader) != nil
                && elapsed >= minimumHeldDuration
            return JobPollResult(job: nil, serverHeldPoll: held)
        case 409:
            struct ServerError: Decodable { let error: String }
            let msg =
                (try? JSONDecoder().decode(ServerError.self, from: data))?.error
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
    case decodingFailed(any Error)

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
        case .decodingFailed(let error):
            return "Failed to decode job payload (server/worker version mismatch?): \(error)"
        }
    }
}
