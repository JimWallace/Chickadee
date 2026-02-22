// Core/RunnerResult.swift
//
// Mirrors the JSON produced by runner scripts (run_tests.sh, run_tests.py).
// The Swift worker parses this document and maps it into TestOutcomeCollection.
// Runners must write ONLY this JSON to stdout; all diagnostics go to stderr.

/// A single test outcome as reported by a runner script.
/// Does not include gamification fields — those are added by the worker.
public struct RunnerOutcome: Codable, Equatable, Sendable {
    public let testName: String
    public let testClass: String?
    public let tier: TestTier
    public let status: TestStatus
    public let shortResult: String
    public let longResult: String?
    public let executionTimeMs: Int
    public let memoryUsageBytes: Int?
}

/// The top-level document written to stdout by every runner script.
public struct RunnerResult: Codable, Equatable, Sendable {
    public let runnerVersion: String
    public let buildStatus: BuildStatus
    public let compilerOutput: String?
    public let executionTimeMs: Int
    public let outcomes: [RunnerOutcome]
}
