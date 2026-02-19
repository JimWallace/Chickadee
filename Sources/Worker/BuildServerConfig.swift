// Worker/BuildServerConfig.swift
//
// Codable configuration struct loaded from JSON at startup.
// Spec §4: "Replace stringly-typed property lookup with a Codable struct
//           that fails at decode time."
//
// Load with:
//   let config = try JSONDecoder().decode(BuildServerConfig.self, from: data)
//
// CLI flags (--api-base-url etc.) remain available and override config-file
// values when both are supplied.

import Foundation

struct BuildServerConfig: Codable {
    /// Base URL of the API server, e.g. "http://buildserver.example.com:8080"
    let apiBaseURL: URL

    /// Unique identifier for this worker instance.
    let workerID: String

    /// Maximum number of submissions processed concurrently.
    let maxConcurrentJobs: Int

    /// Path to the Runners/ directory.
    let runnersDirectory: URL

    /// Path for the PID / lock file used for single-instance enforcement.
    let lockFilePath: URL

    /// swift-log level: "trace", "debug", "info", "notice", "warning", "error", "critical".
    let logLevel: String

    // MARK: - Optional debug overrides (spec §4)

    /// When true, poll once and exit rather than looping.
    let debugDoNotLoop: Bool

    /// If set, process only this specific submission ID and exit.
    let specificSubmission: String?

    // MARK: - Defaults

    init(
        apiBaseURL: URL,
        workerID: String,
        maxConcurrentJobs: Int = 4,
        runnersDirectory: URL,
        lockFilePath: URL,
        logLevel: String = "info",
        debugDoNotLoop: Bool = false,
        specificSubmission: String? = nil
    ) {
        self.apiBaseURL         = apiBaseURL
        self.workerID           = workerID
        self.maxConcurrentJobs  = maxConcurrentJobs
        self.runnersDirectory   = runnersDirectory
        self.lockFilePath       = lockFilePath
        self.logLevel           = logLevel
        self.debugDoNotLoop     = debugDoNotLoop
        self.specificSubmission = specificSubmission
    }
}

extension BuildServerConfig {
    /// Load from a JSON file.  Throws `BuildError.missingConfiguration` with a
    /// clear message if the file is missing or the JSON is malformed.
    static func load(from path: URL) throws -> BuildServerConfig {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw BuildError.missingConfiguration(key: "config file at \(path.path)")
        }
        do {
            let data = try Data(contentsOf: path)
            let decoder = JSONDecoder()
            return try decoder.decode(BuildServerConfig.self, from: data)
        } catch let error as DecodingError {
            throw BuildError.internalError("Config JSON is invalid: \(error)")
        } catch {
            throw BuildError.internalError("Cannot read config file", underlying: error)
        }
    }
}
