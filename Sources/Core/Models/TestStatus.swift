// Core/Models/TestOutcomeStatus.swift

/// The exhaustive set of states a single test case can be in.
///
/// Note: "Could Not Run" is represented at the collection level
/// (buildStatus == .failed), not at the individual test level.
/// Individual tests are only recorded if the build succeeded.
public enum TestOutcomeStatus: String, Codable, Sendable {
    case pass       // Test ran and all assertions passed
    case fail       // Test ran and an assertion failed
    case error      // Test ran but threw an unexpected exception/crash
    case timeout    // Test exceeded the time limit
}
