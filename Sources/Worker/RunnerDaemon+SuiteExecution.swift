// Worker/RunnerDaemon+SuiteExecution.swift
//
// The execute phase of a job: run the suite once, or once per opponent for a
// matrix job, through RunnerCore's shared `executeSuites` loop. Split from
// RunnerDaemon+JobProcessing.swift (#1799).

import Core
import Foundation

extension WorkerDaemon {

    // MARK: - Test execution

    /// Projects the manifest entries to RunnerCore's runtime `SuiteItem` view
    /// and drives the shared `executeSuites` loop. The dependency pass-gate,
    /// skip messages, missing-script handling, and outcome shaping all live in
    /// RunnerCore now — shared byte-for-byte with the browser runner. The worker
    /// supplies its substrate (`NativeScriptExecutor`) and its structured
    /// logging via the event sink.
    func executeTestSuites(
        manifest: TestProperties,
        testSetupDir: URL,
        opponentDir: URL?,
        opponentDirs: [URL],
        job: Job
    ) async throws -> (outcomes: [TestOutcome], matches: [MatchReport]?) {
        // Phase 1 of issue #461 — surface the per-(student, assignment) seed to
        // the grading subprocess. Nil/empty seed means non-personalized job;
        // leaving the env var unset preserves legacy behaviour.
        var baseEnv: [String: String] = [:]
        if let seed = job.assignmentSeed, !seed.isEmpty {
            baseEnv["CHICKADEE_ASSIGNMENT_SEED"] = seed
        }

        // A matrix job (round robin): the suite runs once per opponent, each
        // with that opponent's directory and seed, and the runs fold into one
        // collection plus the per-match rows (`MatrixAggregation.swift`).
        let opponents = job.opponents ?? []
        if !opponents.isEmpty, opponents.count == opponentDirs.count {
            var runs: [MatrixRun] = []
            for (opponent, dir) in zip(opponents, opponentDirs) {
                var env = baseEnv
                env.merge(opponentScriptEnvironment(opponent: opponent, opponentDir: dir)) { _, new in new }
                let outcomes = await runSuite(manifest: manifest, testSetupDir: testSetupDir, env: env, job: job)
                runs.append(MatrixRun(opponent: opponent, outcomes: outcomes))
            }
            return (aggregateMatrixRuns(runs), matrixMatchReports(runs))
        }

        // A match job adds the opponent directory and the per-match seed
        // (docs/class-activities.md); an ordinary job adds nothing.
        var scriptEnv = baseEnv
        scriptEnv.merge(opponentScriptEnvironment(job: job, opponentDir: opponentDir)) { _, new in new }
        return (await runSuite(manifest: manifest, testSetupDir: testSetupDir, env: scriptEnv, job: job), nil)
    }

    /// One pass of the shared suite loop with `env` — the whole of what an
    /// ordinary job does, and one match of a matrix job.
    func runSuite(
        manifest: TestProperties, testSetupDir: URL, env scriptEnv: [String: String], job: Job
    ) async -> [TestOutcome] {

        // Per-student file materialization (`_ck_inputs.py` + dataset slices)
        // happens in `prepareJobWorkspace` — workspace prep, not execution —
        // so `test_execution` stage timing measures only the suite run and the
        // prepare-phase scratch cleanup (#1106) covers materialization throws.

        // Per-test time-limit overrides resolved in the executor (the shared
        // `executeSuites` loop still receives the assignment default below as
        // the fallback). Only entries carrying an explicit positive override
        // are mapped; everything else inherits `manifest.timeLimitSeconds`.
        var timeLimitOverrides: [String: Int] = [:]
        for entry in manifest.testSuites {
            if let limit = entry.timeLimitSeconds, limit > 0 {
                timeLimitOverrides[entry.script] = limit
            }
        }
        let executor = NativeScriptExecutor(
            runner: runner, workDir: testSetupDir, env: scriptEnv, overrides: timeLimitOverrides)
        let items = manifest.testSuites.map { entry in
            SuiteItem(
                script: entry.script,
                tier: entry.tier,
                displayName: entry.name,
                dependsOn: entry.dependsOn,
                points: entry.points
            )
        }

        // Capture only value types so the @Sendable event sink can run on the
        // loop's (nonisolated) executor without touching actor state.
        let runnerID = workerID
        let submissionID = job.submissionID
        return await executeSuites(
            items,
            timeLimitSeconds: manifest.timeLimitSeconds,
            attemptNumber: job.attemptNumber,
            executor: executor,
            onEvent: { event in
                logSuiteRunEvent(event, runnerID: runnerID, submissionID: submissionID)
            }
        )
    }
}

// MARK: - Script output interpretation (pure contract)

// `InterpretedScriptResult` and `interpretScriptOutput(_:)` now live in
// RunnerCore (the wasm-safe leaf shared with the browser runner), as does the
// suite-execution loop itself (`executeSuites` + the `ScriptExecutor` protocol).
// Reached here via `import Core` (which re-exports RunnerCore).

// MARK: - Suite-run event logging

/// Maps RunnerCore's `SuiteRunEvent`s onto the worker's structured log stream,
/// preserving the exact event names and fields the loop used to emit inline
/// (`local_execution_error` / `test_execution_start` / `test_execution_end` /
/// `timeout`). A free function — not an actor method — so the shared
/// `executeSuites` loop can invoke it from its own (nonisolated) executor; it
/// captures only value types.
private func logSuiteRunEvent(_ event: SuiteRunEvent, runnerID: String, submissionID: String) {
    switch event {
    case .missingScript(let script):
        writeStructuredRunnerLog(
            event: "local_execution_error",
            fields: [
                "runner_id": runnerID,
                "submission_id": submissionID,
                "test_id": script,
                "error_type": "missing_script",
                "error_message_summary": script,
            ])
    case .willRun(let script):
        writeStructuredRunnerLog(
            event: "test_execution_start",
            fields: [
                "runner_id": runnerID,
                "submission_id": submissionID,
                "test_id": script,
            ])
    case .didFinish(_, let outcome, let timedOut):
        writeStructuredRunnerLog(
            event: timedOut ? "timeout" : "test_execution_end",
            fields: [
                "runner_id": runnerID,
                "submission_id": submissionID,
                "test_id": normalizedTestID(for: outcome),
                "status": outcome.status.rawValue,
                "execution_ms": outcome.executionTimeMs,
            ])
    }
}

/// Combines `testClass` + `testName` into the dotted ID used in log events.
/// Free function so both the `WorkerDaemon` actor and the suite-run event sink
/// can call it without crossing an isolation boundary.
func normalizedTestID(for outcome: TestOutcome) -> String {
    let classPart = outcome.testClass?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return classPart.isEmpty ? outcome.testName : "\(classPart).\(outcome.testName)"
}
