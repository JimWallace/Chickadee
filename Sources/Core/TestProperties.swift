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
}


/// Top-level manifest describing how to build and test a submission.
public struct TestProperties: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let language: BuildLanguage
    public let requiredFiles: [String]
    public let testSuites: [TestSuiteEntry]
    public let limits: ResourceLimits
}
