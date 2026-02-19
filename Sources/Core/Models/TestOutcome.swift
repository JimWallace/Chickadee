// Core/Models/TestOutcome.swift

/// The complete record for a single test case execution.
///
/// Fields marked "gamification" are present from day one but can be
/// null/zero until the corresponding feature is implemented.
struct TestOutcome: Codable, Equatable, Sendable {

    // MARK: - Identity
    let testName: String        // e.g. "testBitCount"
    let testClass: String?      // e.g. "PublicTests" (nil for Python)
    let tier: TestTier

    // MARK: - Result
    let status: TestOutcomeStatus
    let shortResult: String     // One-line human-readable summary
    let longResult: String?     // Full output, stack trace, diff, etc.

    // MARK: - Performance
    let executionTimeMs: Int
    let memoryUsageBytes: Int?  // gamification — null if not measured yet

    // MARK: - Gamification (future-ready, nullable now)
    let score: Double?          // 0.0–1.0 for partial credit; null = binary
    let attemptNumber: Int      // Which attempt this was (starts at 1)
    let isFirstPassSuccess: Bool // true if passed on attempt 1
}
