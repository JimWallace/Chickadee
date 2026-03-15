// Core/TestProperties.swift
//
// Replaces legacy test.properties. Stored as JSON inside the test setup
// zip uploaded by the instructor.

/// Where and how a submission is graded.
///
/// - `worker`: The submission is queued for a native runner on the server
///   (default — handles shell-script and Python test suites).
/// - `browser`: The student's browser runs tests locally via Pyodide and
///   POSTs the notebook + `TestOutcomeCollection` in one atomic call.
///   No server-side runner is involved.
///
/// Default when the field is absent from JSON: `.worker`.
public enum GradingMode: String, Codable, Sendable, Equatable {
    case browser
    case worker
}

/// Entry for a single test in the manifest.
/// `script` is the filename/path of a runnable test script in the test setup zip.
/// `dependsOn` is an optional list of other `script` names that must pass before
/// this test is executed. If any dependency did not pass, this test is auto-failed.
public struct TestSuiteEntry: Codable, Equatable, Sendable {
    public let tier: TestTier
    public let script: String      // e.g. "01_public.py"
    public let dependsOn: [String] // script names of prerequisites; empty == no deps

    public init(tier: TestTier, script: String, dependsOn: [String] = []) {
        self.tier      = tier
        self.script    = script
        self.dependsOn = dependsOn
    }

    public init(from decoder: Decoder) throws {
        let c     = try decoder.container(keyedBy: CodingKeys.self)
        tier      = try c.decode(TestTier.self,    forKey: .tier)
        script    = try c.decode(String.self,      forKey: .script)
        dependsOn = try c.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
    }
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
        gradingMode      = try c.decodeIfPresent(GradingMode.self,      forKey: .gradingMode)      ?? .worker
        requiredFiles    = try c.decodeIfPresent([String].self,         forKey: .requiredFiles)    ?? []
        testSuites       = try c.decodeIfPresent([TestSuiteEntry].self, forKey: .testSuites)       ?? []
        timeLimitSeconds = try c.decodeIfPresent(Int.self,              forKey: .timeLimitSeconds) ?? 10
        makefile         = try c.decodeIfPresent(MakefileConfig.self,   forKey: .makefile)
    }
}
