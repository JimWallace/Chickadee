// Core/Models/TestOutcomeCollection.swift

import Foundation

/// Build status at the collection (submission) level.
enum BuildStatus: String, Codable, Sendable {
    case passed
    case failed
    case skipped   // e.g. download-only mode during development
}

/// The complete result for one submission run.
struct TestOutcomeCollection: Codable, Sendable {

    // MARK: - Submission identity
    let submissionID: String
    let testSetupID: String
    let attemptNumber: Int

    // MARK: - Build
    let buildStatus: BuildStatus
    let compilerOutput: String?    // nil if build succeeded

    // MARK: - Test outcomes
    // Empty if buildStatus == .failed
    let outcomes: [TestOutcome]

    // MARK: - Aggregate stats (derived, stored for query convenience)
    let totalTests: Int
    let passCount: Int
    let failCount: Int
    let errorCount: Int
    let timeoutCount: Int
    let executionTimeMs: Int       // wall time for the full run

    // MARK: - Metadata
    let runnerVersion: String      // e.g. "java-runner/1.0"
    let timestamp: Date
}
