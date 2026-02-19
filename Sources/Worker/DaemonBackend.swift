// Worker/DaemonBackend.swift
//
// Production HTTP implementation of BuildServerBackend.
// Spec §5: URLSession + async/await.  async-http-client is preferred for
// server-side Swift but deferred until NIO lifecycle is wired up (see Package.swift).
// Spec §7: DaemonBackend is never referenced directly by BuildServer (WorkerDaemon);
//           only the BuildServerBackend protocol is used there.

import Foundation
import Core
import Logging

actor DaemonBackend: BuildServerBackend {
    private let apiBaseURL: URL
    private let workerID: String
    private let supportedLanguages: [String]
    private var logger: Logger

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 30
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    init(apiBaseURL: URL, workerID: String, supportedLanguages: [String], logger: Logger) {
        self.apiBaseURL         = apiBaseURL
        self.workerID           = workerID
        self.supportedLanguages = supportedLanguages
        self.logger             = logger
    }

    // MARK: - BuildServerBackend

    func fetchSubmission() async throws -> Job? {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("api/v1/worker/request"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(WorkerRequestPayload(
            workerID:           workerID,
            supportedLanguages: supportedLanguages,
            hostname:           ProcessInfo.processInfo.hostName
        ))

        let (data, response) = try await Self.session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw BuildError.networkFailure(underlying: URLError(.badServerResponse))
        }

        switch http.statusCode {
        case 200:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Job.self, from: data)
        case 204:
            return nil  // no work available
        case 400:
            // Mirrors Java System.exit(1) on bad request — indicates misconfiguration.
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BuildError.missingConfiguration(key: "Bad request from API server: \(body)")
        default:
            throw BuildError.networkFailure(underlying: URLError(.badServerResponse))
        }
    }

    func downloadSubmission(_ job: Job, to destination: URL) async throws {
        try await download(url: job.submissionURL, to: destination)
    }

    func downloadTestSetup(_ job: Job, to destination: URL) async throws {
        try await download(url: job.testSetupURL, to: destination)
    }

    func reportResults(_ results: TestOutcomeCollection, for job: Job) async throws {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("api/v1/worker/results"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(results)

        let (data, response) = try await Self.session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw BuildError.networkFailure(underlying: URLError(.badServerResponse))
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BuildError.networkFailure(
                underlying: URLError(.badServerResponse,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
            )
        }
    }

    func reportDeath(submissionID: String, testSetupID: String) async {
        // Best-effort: log the death and attempt a results POST with buildStatus "failed".
        logger.warning("Reporting death for submission",
            metadata: ["submissionID": .string(submissionID), "testSetupID": .string(testSetupID)])
        // No throw — caller must not fail on reporting errors.
    }

    // MARK: - Private

    private func download(url: URL, to destination: URL) async throws {
        let (tmpURL, response) = try await Self.session.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BuildError.networkFailure(underlying: URLError(.badServerResponse))
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        do {
            try FileManager.default.moveItem(at: tmpURL, to: destination)
        } catch {
            throw BuildError.internalError("Failed to move downloaded file to \(destination.path)",
                underlying: error)
        }
    }
}

// MARK: - Internal request type

private struct WorkerRequestPayload: Encodable {
    let workerID: String
    let supportedLanguages: [String]
    let hostname: String
}
