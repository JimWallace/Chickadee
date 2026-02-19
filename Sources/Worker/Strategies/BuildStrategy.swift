// Worker/Strategies/BuildStrategy.swift
//
// Spec §7: protocol-based polymorphism; all errors use BuildError.

import Foundation
import Core

/// Protocol all language-specific build strategies must conform to.
protocol BuildStrategy {
    var language: BuildLanguage { get }

    /// Validate that the runner environment is available (e.g. python3 on PATH).
    /// Throws `BuildError.internalError` if a required tool is missing.
    func preflight() async throws

    /// Run the full build + test cycle for a submission.
    /// - Throws: `BuildError.compileFailure` on a build error reported by the runner;
    ///   `BuildError.internalError` on infrastructure failures.
    func run(
        submission: URL,
        testSetup: URL,
        manifest: TestSetupManifest
    ) async throws -> RunnerResult
}
