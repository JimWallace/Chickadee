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

    // MARK: - Weighted grade stats
    /// Sum of `points` for all outcomes. Equals `totalTests` when all weights are 1.
    public let totalPoints: Int
    /// Sum of `points` for passing outcomes. Equals `passCount` when all weights are 1.
    public let earnedPoints: Int

    // MARK: - Metadata
    public let runnerVersion: String      // e.g. "shell-runner/1.0"
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
        totalPoints: Int? = nil,
        earnedPoints: Int? = nil,
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
        self.totalPoints     = totalPoints  ?? totalTests
        self.earnedPoints    = earnedPoints ?? passCount
        self.runnerVersion   = runnerVersion
        self.timestamp       = timestamp
    }

    // Custom decoder so old records without totalPoints/earnedPoints fall back
    // to totalTests/passCount, preserving correct grade display for existing results.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        submissionID    = try c.decode(String.self,        forKey: .submissionID)
        testSetupID     = try c.decode(String.self,        forKey: .testSetupID)
        attemptNumber   = try c.decode(Int.self,           forKey: .attemptNumber)
        buildStatus     = try c.decode(BuildStatus.self,   forKey: .buildStatus)
        compilerOutput  = try c.decodeIfPresent(String.self, forKey: .compilerOutput)
        outcomes        = try c.decode([TestOutcome].self, forKey: .outcomes)
        totalTests      = try c.decode(Int.self,           forKey: .totalTests)
        passCount       = try c.decode(Int.self,           forKey: .passCount)
        failCount       = try c.decode(Int.self,           forKey: .failCount)
        errorCount      = try c.decode(Int.self,           forKey: .errorCount)
        timeoutCount    = try c.decode(Int.self,           forKey: .timeoutCount)
        executionTimeMs = try c.decode(Int.self,           forKey: .executionTimeMs)
        totalPoints     = try c.decodeIfPresent(Int.self,  forKey: .totalPoints)  ?? totalTests
        earnedPoints    = try c.decodeIfPresent(Int.self,  forKey: .earnedPoints) ?? passCount
        runnerVersion   = try c.decode(String.self,        forKey: .runnerVersion)
        timestamp       = try c.decode(Date.self,          forKey: .timestamp)
    }
}
