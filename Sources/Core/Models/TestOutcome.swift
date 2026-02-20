// Core/Models/TestOutcome.swift

/// The complete record for a single test case execution.
///
/// Fields marked "gamification" are present from day one but can be
/// null/zero until the corresponding feature is implemented.
public struct TestOutcome: Codable, Equatable, Sendable {

    // MARK: - Identity
    public let testName: String        // e.g. "testBitCount"
    public let testClass: String?      // e.g. "PublicTests" (nil for Python)
    public let tier: TestTier

    // MARK: - Result
    public let status: TestStatus
    public let shortResult: String     // One-line human-readable summary
    public let longResult: String?     // Full output, stack trace, diff, etc.

    // MARK: - Performance
    public let executionTimeMs: Int
    public let memoryUsageBytes: Int?  // gamification — null if not measured yet

    // MARK: - Gamification (future-ready, nullable now)
    public let attemptNumber: Int      // Which attempt this was (starts at 1)
    public let isFirstPassSuccess: Bool // true if passed on attempt 1

    public init(
        testName: String,
        testClass: String?,
        tier: TestTier,
        status: TestStatus,
        shortResult: String,
        longResult: String?,
        executionTimeMs: Int,
        memoryUsageBytes: Int?,
        attemptNumber: Int,
        isFirstPassSuccess: Bool
    ) {
        self.testName            = testName
        self.testClass           = testClass
        self.tier                = tier
        self.status              = status
        self.shortResult         = shortResult
        self.longResult          = longResult
        self.executionTimeMs     = executionTimeMs
        self.memoryUsageBytes    = memoryUsageBytes
        self.attemptNumber       = attemptNumber
        self.isFirstPassSuccess  = isFirstPassSuccess
    }
}
