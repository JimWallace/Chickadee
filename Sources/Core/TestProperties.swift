// Core/TestProperties.swift
//
// Replaces legacy test.properties. Stored as JSON inside the test setup
// zip uploaded by the instructor.

/// Where and how a submission is graded.
///
/// - `browser`: The student's browser runs the notebook via Pyodide and POSTs
///   a preliminary `TestOutcomeCollection`. The server also enqueues the
///   submission for a worker re-run that produces the official grade.
/// - `worker`: The submission is queued for a worker immediately on upload
///   (existing behaviour for shell-script test suites).
///
/// Default when the field is absent from JSON: `.browser`.
public enum GradingMode: String, Codable, Sendable, Equatable {
    case browser
    case worker
}

/// Entry for a single test in the manifest.
/// `script` is the filename/path of a runnable test script in the test setup zip.
public struct TestSuiteEntry: Codable, Equatable, Sendable {
    public let tier: TestTier
    public let script: String      // e.g. "01_public.py"
}

/// Optional Makefile step to run before tests.
public struct MakefileConfig: Codable, Equatable, Sendable {
    public let target: String?     // nil means bare `make` with no target
}

/// Top-level manifest describing how to build and test a submission.
public struct TestProperties: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let gradingMode: GradingMode
    public let requiredFiles: [String]
    public let testSuites: [TestSuiteEntry]
    public let timeLimitSeconds: Int
    public let makefile: MakefileConfig?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion    = try c.decode(Int.self,                       forKey: .schemaVersion)
        gradingMode      = try c.decodeIfPresent(GradingMode.self,      forKey: .gradingMode)      ?? .browser
        requiredFiles    = try c.decodeIfPresent([String].self,         forKey: .requiredFiles)    ?? []
        testSuites       = try c.decodeIfPresent([TestSuiteEntry].self, forKey: .testSuites)       ?? []
        timeLimitSeconds = try c.decodeIfPresent(Int.self,              forKey: .timeLimitSeconds) ?? 10
        makefile         = try c.decodeIfPresent(MakefileConfig.self,   forKey: .makefile)
    }
}
