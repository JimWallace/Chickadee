// Core/TestProperties.swift
//
// Replaces legacy test.properties. Stored as JSON inside the test setup
// zip uploaded by the instructor.

/// Entry for a single test in the manifest.
/// `script` is the filename of the shell script at the root of the test setup zip.
public struct TestSuiteEntry: Codable, Equatable, Sendable {
    public let tier: TestTier
    public let script: String      // e.g. "test_bit_count.sh"
}

/// Optional Makefile step to run before tests.
public struct MakefileConfig: Codable, Equatable, Sendable {
    public let target: String?     // nil means bare `make` with no target
}

/// Top-level manifest describing how to build and test a submission.
public struct TestProperties: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requiredFiles: [String]
    public let testSuites: [TestSuiteEntry]
    public let timeLimitSeconds: Int
    public let makefile: MakefileConfig?
}
