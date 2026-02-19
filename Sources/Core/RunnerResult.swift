// Core/RunnerResult.swift
//
// Mirrors the JSON produced by runner scripts (run_tests.sh, run_tests.py).
// The Swift worker parses this document and maps it into TestOutcomeCollection.
// Runners must write ONLY this JSON to stdout; all diagnostics go to stderr.

/// A single test outcome as reported by a runner script.
/// Does not include gamification fields — those are added by the worker.
struct RunnerOutcome: Codable, Equatable, Sendable {
    let testName: String
    let testClass: String?
    let tier: TestTier
    let status: TestOutcomeStatus
    let shortResult: String
    let longResult: String?
    let executionTimeMs: Int
    let memoryUsageBytes: Int?
}

/// The top-level document written to stdout by every runner script.
struct RunnerResult: Codable, Equatable, Sendable {
    let runnerVersion: String
    let buildStatus: BuildStatus
    let compilerOutput: String?
    let executionTimeMs: Int
    let outcomes: [RunnerOutcome]
}
