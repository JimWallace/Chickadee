// Core/TestSetupManifest.swift
//
// Replaces legacy test.properties. Stored as JSON inside the test setup
// zip uploaded by the instructor.

/// Entry for a single test suite in the manifest.
/// `module` is the pytest module name (Python) or notebook filename (Jupyter).
public struct TestSuiteEntry: Codable, Equatable, Sendable {
    public let tier: TestTier
    public let module: String      // Python: pytest module; Jupyter: .ipynb filename
}

/// Resource limits applied to the runner subprocess.
public struct ResourceLimits: Codable, Equatable, Sendable {
    public let timeLimitSeconds: Int
    public let memoryLimitMb: Int
}

/// Optional behavioural flags for a test setup.
public struct ManifestOptions: Codable, Equatable, Sendable {
    public let allowPartialCredit: Bool
}

/// Configuration for an optional Makefile step that runs before tests.
///
/// If present in the manifest, the runner invokes `make [target]` in the
/// working directory before executing any test suites. A non-zero exit from
/// make is reported as `buildStatus: "failed"` with make's output in
/// `compilerOutput`. The Makefile itself must be included in the test setup zip.
public struct MakefileConfig: Codable, Equatable, Sendable {
    /// The make target to invoke. `nil` runs the default target (bare `make`).
    public let target: String?
}

/// Top-level manifest describing how to build and test a submission.
public struct TestSetupManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let language: BuildLanguage
    public let requiredFiles: [String]
    public let testSuites: [TestSuiteEntry]
    public let limits: ResourceLimits
    public let options: ManifestOptions
    /// If present, `make [target]` is run before tests. Nil means no Makefile step.
    public let makefile: MakefileConfig?
}
