// Tests/WorkerTests/Support/NativeGradingHarness.swift
//
// The workspace and the suite run that the native-grading suites share
// (LuaNativeGradingTests, CppNativeGradingTests, OctaveNativeGradingTests,
// JavaNativeGradingTests and RacketNativeGradingTests). Each suite used to
// carry its own copy. The copies differed only in the language, the
// submission's file name and the time limit, so those three are the fields.

import Core
import Foundation
import RunnerCore

@testable import chickadee_runner

/// Builds a grading workspace for one language and runs suites in it through
/// the real `UnsandboxedScriptRunner`.
struct NativeGradingHarness {
    /// The language whose runtime helpers go into each workspace.
    let language: AssignmentLanguage
    /// The file name of the student's submission. The hint file names it.
    let solutionFilename: String
    /// The time limit that `runSuites` gives each script.
    let timeLimitSeconds: Int

    /// A grading workspace shaped like the one `RunnerDaemon` materializes:
    /// the injected runtime, the student's submission, and the hint file that
    /// tells the runtime which upload to grade.
    ///
    /// The runtime files come from `runtimeHelperFiles(for:)`, which is the
    /// installer loop's own source. So a runtime change that breaks native
    /// grading fails here, and so does a helper that the loop does not write.
    func makeWorkspace(submission: String, scripts: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-\(language.rawValue)native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for (name, source) in runtimeHelperFiles(for: language) {
            try source.write(
                to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try submission.write(
            to: dir.appendingPathComponent(solutionFilename), atomically: true, encoding: .utf8)
        try solutionFilename.write(
            to: dir.appendingPathComponent(".chickadee_student_module"),
            atomically: true, encoding: .utf8)
        for (name, source) in scripts {
            try source.write(
                to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir
    }

    /// Runs `items` in `dir` the way the worker does, through `executeSuites`.
    func runSuites(_ items: [SuiteItem], in dir: URL) async -> [TestOutcome] {
        let executor = NativeScriptExecutor(
            runner: UnsandboxedScriptRunner(), workDir: dir, overrides: [:])
        return await executeSuites(
            items, timeLimitSeconds: timeLimitSeconds, attemptNumber: 1, executor: executor)
    }

    /// One public suite item worth one point, with no dependencies.
    static func item(_ script: String) -> SuiteItem {
        SuiteItem(script: script, tier: .pub, displayName: script, dependsOn: [], points: 1)
    }
}
