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

/// Top-level manifest describing how to build and test a submission.
struct TestSetupManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let language: BuildLanguage
    let requiredFiles: [String]
    let testSuites: [TestSuiteEntry]
    let limits: ResourceLimits
    let options: ManifestOptions
}
