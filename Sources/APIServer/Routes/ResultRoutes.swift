// APIServer/Routes/ResultRoutes.swift
//
// Phase 2: persists TestOutcomeCollection to both the DB (results table) and
// to a JSON file on disk, then marks the originating submission as complete.

import Vapor
import Fluent
import Core
import Foundation

struct ResultRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let api = routes.grouped("api", "v1", "worker")
        api.post("results", use: reportResults)
    }

    // POST /api/v1/worker/results
    @Sendable
    func reportResults(req: Request) async throws -> ReportResponse {
        try await requireWorkerSecret(req)

        if let workerID = req.headers.first(name: "X-Worker-Id"), !workerID.isEmpty {
            await req.application.workerActivityStore.markActive(workerID: workerID)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let collection: TestOutcomeCollection
        do {
            var buffer = try await req.body.collect(upTo: req.application.routes.defaultMaxBodySize.value)
            guard let data = buffer.readData(length: buffer.readableBytes) else {
                throw Abort(.badRequest, reason: "Empty request body")
            }
            collection = try decoder.decode(TestOutcomeCollection.self, from: data)
        } catch let decodingError as DecodingError {
            throw Abort(.unprocessableEntity, reason: "Invalid TestOutcomeCollection: \(decodingError)")
        }

        // Persist to DB and disk concurrently.
        async let db: Void   = persistToDB(collection, on: req)
        async let disk: Void = persistToDisk(collection, on: req)
        _ = try await (db, disk)

        // Advance the submission's state machine to "complete".
        if let submission = try await APISubmission.find(collection.submissionID, on: req.db) {
            submission.status = "complete"
            try await submission.save(on: req.db)
        }

        return ReportResponse(received: true)
    }

    // MARK: - DB persistence

    private func persistToDB(_ collection: TestOutcomeCollection, on req: Request) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try String(data: encoder.encode(collection), encoding: .utf8) ?? "{}"

        let result = APIResult(
            id:             "res_\(UUID().uuidString.lowercased().prefix(8))",
            submissionID:   collection.submissionID,
            collectionJSON: json
        )
        try await result.save(on: req.db)
    }

    // MARK: - Disk persistence (kept for easy inspection / debugging)

    private func persistToDisk(_ collection: TestOutcomeCollection, on req: Request) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting    = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data      = try encoder.encode(collection)
        let timestamp = ISO8601DateFormatter().string(from: collection.timestamp)
            .replacingOccurrences(of: ":", with: "-")
        let filename  = "\(collection.submissionID)_\(timestamp).json"
        let filePath  = req.application.resultsDirectory + filename

        try await req.fileio.writeFile(.init(data: data), at: filePath)
        req.logger.info("Stored result for submission \(collection.submissionID) at \(filePath)")
    }
}

// MARK: - Response

struct ReportResponse: Content {
    let received: Bool
}
