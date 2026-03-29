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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let collection: TestOutcomeCollection
        do {
            let collectedBuffer = try await req.body.collect(
                upTo: req.application.routes.defaultMaxBodySize.value
            )
            var readableBuffer = collectedBuffer
            guard let data = readableBuffer.readData(length: readableBuffer.readableBytes) else {
                throw Abort(.badRequest, reason: "Empty request body")
            }
            collection = try decoder.decode(TestOutcomeCollection.self, from: data)
        } catch let decodingError as DecodingError {
            throw Abort(.unprocessableEntity, reason: "Invalid TestOutcomeCollection: \(decodingError)")
        }

        async let dbPersist: Void   = persistToDB(collection, on: req)
        async let diskPersist: Void = persistToDisk(collection, on: req)
        try await dbPersist
        try await diskPersist

        // Advance the submission's state machine to "complete".
        if let submission = try await APISubmission.find(collection.submissionID, on: req.db) {
            submission.status = "complete"
            try await submission.save(on: req.db)

            // If this is a validation submission, update the assignment's validationStatus
            // so the instructor sees pass/fail without needing to poll.
            if submission.kind == APISubmission.Kind.validation {
                let passed = collection.buildStatus == .passed
                    && collection.failCount == 0
                    && collection.errorCount == 0
                    && collection.timeoutCount == 0
                let status = passed ? "passed" : "failed"

                if let assignment = try await APIAssignment.query(on: req.db)
                    .filter(\.$validationSubmissionID == submission.id!)
                    .first() {
                    assignment.validationStatus = status
                    try await assignment.save(on: req.db)
                    req.logger.info("Validation \(status) for assignment '\(assignment.title)' (submission \(submission.id!))")
                }
            }
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
