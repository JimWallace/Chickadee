// Core/TestSetupManifest.swift
//
// Replaces legacy test.properties. Stored as JSON inside the test setup
// zip uploaded by the instructor.

/// Entry for a single test suite in the manifest.
/// `module` is the pytest module name (Python) or notebook filename (Jupyter).
struct TestSuiteEntry: Codable, Equatable, Sendable {
    let tier: TestTier
    let module: String      // Python: pytest module; Jupyter: .ipynb filename
}

/// Resource limits applied to the runner subprocess.
struct ResourceLimits: Codable, Equatable, Sendable {
    let timeLimitSeconds: Int
    let memoryLimitMb: Int
}

/// Optional behavioural flags for a test setup.
struct ManifestOptions: Codable, Equatable, Sendable {
    let allowPartialCredit: Bool
}

/// Configuration for an optional Makefile step that runs before tests.
///
/// If present in the manifest, the runner invokes `make [target]` in the
/// working directory before executing any test suites. A non-zero exit from
/// make is reported as `buildStatus: "failed"` with make's output in
/// `compilerOutput`. The Makefile itself must be included in the test setup zip.
struct MakefileConfig: Codable, Equatable, Sendable {
    /// The make target to invoke. `nil` runs the default target (bare `make`).
    let target: String?
}

/// Top-level manifest describing how to build and test a submission.
struct TestSetupManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let language: BuildLanguage
    let requiredFiles: [String]
    let testSuites: [TestSuiteEntry]
    let limits: ResourceLimits
    let options: ManifestOptions
    /// If present, `make [target]` is run before tests. Nil means no Makefile step.
    let makefile: MakefileConfig?
}
