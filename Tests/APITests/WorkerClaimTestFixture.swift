// Tests/APITests/WorkerClaimTestFixture.swift
//
// Result ingest accepts a report only for the claim the reporting runner
// holds (`ResultClaimCheck`). A test that posts a worker result for a row it
// created directly first marks the row claimed, as the claim statement would.

import Fluent
import Foundation

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
