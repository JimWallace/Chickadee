// Tests/APITests/WorkerClaimTestFixture.swift
//
// Result ingest accepts a report only for the claim the reporting runner
// holds (`ResultClaimCheck`). A test that posts a worker result for a row it
// created directly first marks the row claimed, as the claim statement would,
// then posts the report the way a runner does.

import Fluent
import Foundation
import NIOCore
import NIOFoundationCompat
import VaporTesting

@testable import APIServer
@testable import Core

/// Marks `submissionID` assigned to `workerID`, the id `workerHMACHeaders`
/// signs with by default, so a result posted for it answers a current claim.
func markClaimedForResultReport(
    _ submissionID: String, workerID: String = "test-runner", on db: any Database
) async throws {
    try await APISubmission.query(on: db)
        .filter(\.$id == submissionID)
        .set(\.$status, to: SubmissionStatus.assigned.rawValue)
        .set(\.$workerID, to: workerID)
        .set(\.$assignedAt, to: Date())
        .update()
}

/// The body a runner posts to `/api/v1/worker/results`: `collection` wrapped
/// in a `WorkerExecutionReport`, with ISO 8601 dates.
func workerReportBody(_ collection: TestOutcomeCollection) throws -> ByteBuffer {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return ByteBuffer(data: try encoder.encode(WorkerExecutionReport(collection: collection, diagnostics: nil)))
}

/// Posts `collection` as a runner would, signed with `workerSecret` under the
/// default worker id, through the real result route.
func postWorkerReport(
    _ app: Application, _ collection: TestOutcomeCollection, workerSecret: String
) async throws -> TestResponse {
    let path = "/api/v1/worker/results"
    let body = try workerReportBody(collection)
    let headers = workerHMACHeaders(method: .POST, path: path, body: body, workerSecret: workerSecret)
    return try await app.asyncSendRequest(.POST, path) { req in
        req.headers = headers
        req.body = body
    }
}
