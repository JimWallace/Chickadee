// APIServer/Routes/ResultRoutes.swift
//
// Phase 1: single endpoint that accepts a TestOutcomeCollection and
// persists it as a JSON file on disk. No database dependency.

import Vapor
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let collection: TestOutcomeCollection
        do {
            let body = try req.body.collect().get()
            guard let data = body.getData(at: 0, length: body.readableBytes) else {
                throw Abort(.badRequest, reason: "Empty request body")
            }
            collection = try decoder.decode(TestOutcomeCollection.self, from: data)
        } catch let decodingError as DecodingError {
            throw Abort(.unprocessableEntity, reason: "Invalid TestOutcomeCollection: \(decodingError)")
        }

        try await persist(collection, on: req)

        return ReportResponse(received: true)
    }

    // MARK: - Persistence

    private func persist(_ collection: TestOutcomeCollection, on req: Request) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(collection)

        let timestamp = ISO8601DateFormatter().string(from: collection.timestamp)
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(collection.submissionID)_\(timestamp).json"
        let resultsDir = req.application.resultsDirectory
        let filePath = resultsDir + filename

        try await req.fileio.writeFile(.init(data: data), at: filePath)

        req.logger.info("Stored result for submission \(collection.submissionID) at \(filePath)")
    }
}

// MARK: - Response

struct ReportResponse: Content {
    let received: Bool
}
