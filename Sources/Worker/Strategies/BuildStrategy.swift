// Worker/Strategies/BuildStrategy.swift

import Foundation
import Core

/// Protocol all language-specific build strategies must conform to.
protocol BuildStrategy {
    var language: BuildLanguage { get }

    /// Validate that the runner environment is available
    /// (e.g. javac is on PATH). Called once at startup.
    func preflight() async throws

    /// Run the full build + test cycle for a submission.
    /// - Parameters:
    ///   - submission: URL of the submission zip file on disk.
    ///   - testSetup: URL of the directory containing test class files and the manifest.
    ///   - manifest: Parsed test setup manifest.
    /// - Returns: The parsed RunnerResult from the runner script.
    func run(
        submission: URL,
        testSetup: URL,
        manifest: TestProperties
    ) async throws -> RunnerResult
}

/// Errors thrown by build strategies.
enum BuildStrategyError: Error, LocalizedError {
    case toolNotFound(String)
    case runnerScriptNotFound(URL)
    case runnerFailed(exitCode: Int32, stderr: String)
    case invalidRunnerOutput(String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            return "Required tool not found on PATH: \(tool)"
        case .runnerScriptNotFound(let url):
            return "Runner script not found at: \(url.path)"
        case .runnerFailed(let code, let stderr):
            return "Runner exited with code \(code): \(stderr)"
        case .invalidRunnerOutput(let detail):
            return "Could not parse runner JSON output: \(detail)"
        }
    }
}
