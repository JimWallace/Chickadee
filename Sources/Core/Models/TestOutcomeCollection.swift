// Core/Models/TestOutcomeCollection.swift

import Foundation

/// Build status at the collection (submission) level.
public enum BuildStatus: String, Codable, Sendable {
    case passed
    case failed
    case skipped   // e.g. download-only mode during development
}

/// The complete result for one submission run.
public struct TestOutcomeCollection: Codable, Sendable {

    // MARK: - Submission identity
    public let submissionID: String
    public let testSetupID: String
    public let attemptNumber: Int

    // MARK: - Build
    public let buildStatus: BuildStatus
    public let compilerOutput: String?    // nil if build succeeded

    // MARK: - Test outcomes
    // Empty if buildStatus == .failed
    public let outcomes: [TestOutcome]

    // MARK: - Aggregate stats (derived, stored for query convenience)
    public let totalTests: Int
    public let passCount: Int
    public let failCount: Int
    public let errorCount: Int
    public let timeoutCount: Int
    public let executionTimeMs: Int       // wall time for the full run

    // MARK: - Metadata
    public let runnerVersion: String      // e.g. "java-runner/1.0"
    public let timestamp: Date

    public init(
        submissionID: String,
        testSetupID: String,
        attemptNumber: Int,
        buildStatus: BuildStatus,
        compilerOutput: String?,
        outcomes: [TestOutcome],
        totalTests: Int,
        passCount: Int,
        failCount: Int,
        errorCount: Int,
        timeoutCount: Int,
        executionTimeMs: Int,
        runnerVersion: String,
        timestamp: Date
    ) {
        self.submissionID    = submissionID
        self.testSetupID     = testSetupID
        self.attemptNumber   = attemptNumber
        self.buildStatus     = buildStatus
        self.compilerOutput  = compilerOutput
        self.outcomes        = outcomes
        self.totalTests      = totalTests
        self.passCount       = passCount
        self.failCount       = failCount
        self.errorCount      = errorCount
        self.timeoutCount    = timeoutCount
        self.executionTimeMs = executionTimeMs
        self.runnerVersion   = runnerVersion
        self.timestamp       = timestamp
    }
}
