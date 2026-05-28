// RunnerCore/SuiteExecution.swift
//
// The suite-execution loop — the single piece of logic that has repeatedly
// drifted between the native worker and the browser runner (dependency gating,
// skip messages, missing-script handling, outcome shaping). It lives here once,
// in the wasm-safe leaf, and both runners drive it through a `ScriptExecutor`.
//
// "A runner" is not a protocol; it is the composition `executeSuites` + some
// `ScriptExecutor`. The worker is the first conformance; the browser runner is
// a drop-in second one.
//
// Foundation-free so it compiles to Embedded Swift.
//
// `import _Concurrency` is REQUIRED here: Embedded Swift only lowers `async`
// code when the concurrency module is imported in the file. Without it, SILGen
// crashes (signal 11) instead of emitting a diagnostic. The runtime supplies
// the executor — on wasm it's the single cooperative executor — so `await`ing
// the substrate (subprocess on the worker, Pyodide in the browser) just works.
import _Concurrency

/// The `shortResult` emitted when a test is auto-failed because one of its
/// `dependsOn` prerequisites did not pass. Both grading runners emit this exact
/// string — the native worker and the browser runner — and two consumers parse
/// it back: the server results view (`parseSkip` in `SubmissionOutputFormatting`)
/// and `notebook.js`. Keeping the wording here (and pinned by the shared
/// `Tests/Fixtures/dependency-skip-message.json` fixture) is what stops the
/// producers and parsers from drifting apart. Hoisted into RunnerCore so the
/// one producer of this string is shared by both runners.
public func skippedPrerequisiteMessage(prerequisite: String) -> String {
    "Skipped: prerequisite '\(prerequisite)' did not pass"
}

/// Walks `suites` in order, honouring the `dependsOn` pass-gate: a test whose
/// prerequisite hasn't passed is auto-failed with a `Skipped:` short result
/// instead of executed. Missing script files emit a `.missingScript` event and
/// are skipped entirely (no outcome — matching long-standing worker behaviour).
///
/// - Parameters:
///   - suites: the manifest entries, projected to the runtime view, in order.
///   - timeLimitSeconds: per-script wall-clock limit, enforced by the executor.
///   - attemptNumber: stamped onto every outcome; drives `isFirstPassSuccess`.
///   - executor: the substrate that actually runs scripts (subprocess / Pyodide).
///   - onEvent: observability sink; the loop does no logging itself.
/// - Returns: one `TestOutcome` per executed-or-skipped entry, in suite order.
public func executeSuites(
    _ suites: [SuiteItem],
    timeLimitSeconds: Int,
    attemptNumber: Int,
    executor: some ScriptExecutor,
    onEvent: @Sendable (SuiteRunEvent) -> Void = { _ in }
) async -> [TestOutcome] {
    var outcomes: [TestOutcome] = []
    var passedScripts: [String] = []

    for item in suites {
        // Dependency gate: auto-fail (don't run) if a prerequisite hasn't passed.
        if let blockedBy = item.dependsOn.first(where: { !passedScripts.contains($0) }),
            !item.dependsOn.isEmpty
        {
            outcomes.append(
                TestOutcome(
                    testName: outcomeTestName(for: item),
                    testClass: nil,
                    tier: item.tier,
                    status: .fail,
                    shortResult: skippedPrerequisiteMessage(prerequisite: blockedBy),
                    longResult: nil,
                    points: item.points,
                    executionTimeMs: 0,
                    memoryUsageBytes: nil,
                    attemptNumber: attemptNumber,
                    isFirstPassSuccess: false
                ))
            continue
        }

        // Missing-script: skip with no outcome (caller logs via the event).
        guard await executor.scriptExists(item.script) else {
            onEvent(.missingScript(script: item.script))
            continue
        }

        onEvent(.willRun(script: item.script))
        let output = await executor.run(script: item.script, timeLimitSeconds: timeLimitSeconds)
        let outcome = makeOutcome(item: item, output: output, attemptNumber: attemptNumber)
        outcomes.append(outcome)
        onEvent(.didFinish(script: item.script, outcome: outcome, timedOut: output.timedOut))

        if outcome.status == .pass {
            passedScripts.append(item.script)
        }
    }

    return outcomes
}

/// Builds the `TestOutcome` for a script that actually ran, applying the shared
/// interpretation (`interpretScriptOutput`) and the display-name rules.
private func makeOutcome(item: SuiteItem, output: ScriptOutput, attemptNumber: Int) -> TestOutcome {
    let interpreted = interpretScriptOutput(output)
    return TestOutcome(
        testName: outcomeTestName(for: item),
        testClass: nil,
        tier: item.tier,
        status: interpreted.status,
        shortResult: interpreted.shortResult,
        longResult: interpreted.longResult,
        points: item.points,
        executionTimeMs: output.executionTimeMs,
        memoryUsageBytes: nil,
        attemptNumber: attemptNumber,
        isFirstPassSuccess: attemptNumber == 1 && interpreted.status == .pass
    )
}

/// Display name shown to students: the instructor's name when present and
/// non-blank, otherwise the script filename with its extension stripped (or the
/// raw filename if it has no stem).
private func outcomeTestName(for item: SuiteItem) -> String {
    if let name = nonBlankDisplayName(item.displayName) {
        return name
    }
    let stem = scriptStem(item.script)
    return stem.isEmpty ? item.script : stem
}

/// Returns `name` unchanged if it has any non-(space/tab) character, else nil.
/// Mirrors the worker's `name.trimmingCharacters(in: .whitespaces).isEmpty`
/// check without pulling in Foundation.
private func nonBlankDisplayName(_ name: String?) -> String? {
    guard let name else { return nil }
    for ch in name where ch != " " && ch != "\t" {
        return name
    }
    return nil
}

/// Strips the last filename extension, mirroring `NSString.deletingPathExtension`
/// for the bare-filename case the runner always sees. A leading dot is treated
/// as part of the name (`.gitignore` stays `.gitignore`), and a name with no dot
/// is returned unchanged.
private func scriptStem(_ name: String) -> String {
    guard let dotIndex = name.lastIndex(of: "."), dotIndex != name.startIndex else {
        return name
    }
    return String(name[..<dotIndex])
}
