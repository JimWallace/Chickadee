// Tests/CoreTests/SuiteExecutionTests.swift
//
// Unit tests for RunnerCore's shared `executeSuites` loop — the single,
// substrate-independent implementation of dependency gating, skip messages,
// missing-script handling, and outcome shaping that both the native worker and
// (Stage 4) the browser runner drive through a `ScriptExecutor`. Reached via
// `import Core`, which re-exports RunnerCore.

import Core
import Synchronization
import Testing

/// A deterministic in-memory `ScriptExecutor`: a script "exists" iff it has an
/// entry in `outputs`, and running it returns that entry verbatim.
private struct FakeExecutor: ScriptExecutor {
    let outputs: [String: ScriptOutput]

    func scriptExists(_ name: String) async -> Bool {
        outputs[name] != nil
    }

    func run(script: String, timeLimitSeconds: Int) async -> ScriptOutput {
        outputs[script] ?? ScriptOutput(exitCode: 2, stdout: "", stderr: "", executionTimeMs: 0, timedOut: false)
    }
}

private func pass(_ ms: Int = 1) -> ScriptOutput {
    ScriptOutput(exitCode: 0, stdout: "ok", stderr: "", executionTimeMs: ms, timedOut: false)
}

private func fail() -> ScriptOutput {
    ScriptOutput(exitCode: 1, stdout: "nope", stderr: "", executionTimeMs: 1, timedOut: false)
}

/// Thread-safe event collector usable from the `@Sendable` `onEvent` sink.
private final class EventLog: Sendable {
    private let storage = Mutex<[SuiteRunEvent]>([])
    func record(_ event: SuiteRunEvent) { storage.withLock { $0.append(event) } }
    var events: [SuiteRunEvent] { storage.withLock { $0 } }
}

/// `SuiteRunEvent` is not `Equatable` (it carries a `TestOutcome`), so compare
/// rendered strings — which also makes a failure legible as a sequence diff
/// rather than a pattern-match that silently matched nothing.
private func describe(_ event: SuiteRunEvent) -> String {
    switch event {
    case .missingScript(let s): return "missingScript(\(s))"
    case .willRun(let s): return "willRun(\(s))"
    case .didFinish(let s, let outcome, let timedOut):
        return "didFinish(\(s), \(outcome.status.rawValue), timedOut: \(timedOut))"
    }
}

@Suite struct SuiteExecutionTests {

    @Test func runsEachScriptAndShapesOutcomes() async {
        let executor = FakeExecutor(outputs: ["test_a.py": pass(7), "test_b.py": fail()])
        let suites = [
            SuiteItem(script: "test_a.py", tier: .pub, points: 2),
            SuiteItem(script: "test_b.py", tier: .release, points: 3),
        ]

        let outcomes = await executeSuites(
            suites, timeLimitSeconds: 10, attemptNumber: 1, executor: executor)

        #expect(outcomes.count == 2)
        #expect(outcomes[0].testName == "test_a")  // stem fallback
        #expect(outcomes[0].status == .pass)
        #expect(outcomes[0].tier == .pub)
        #expect(outcomes[0].points == 2)
        #expect(outcomes[0].executionTimeMs == 7)
        #expect(outcomes[0].isFirstPassSuccess == true)
        #expect(outcomes[1].testName == "test_b")
        #expect(outcomes[1].status == .fail)
        #expect(outcomes[1].points == 3)
        #expect(outcomes[1].isFirstPassSuccess == false)
    }

    @Test func dependencyGateSkipsWhenPrerequisiteFails() async {
        let executor = FakeExecutor(outputs: ["a.py": fail(), "b.py": pass()])
        let suites = [
            SuiteItem(script: "a.py", tier: .pub),
            SuiteItem(script: "b.py", tier: .pub, dependsOn: ["a.py"]),
        ]

        let outcomes = await executeSuites(
            suites, timeLimitSeconds: 10, attemptNumber: 1, executor: executor)

        #expect(outcomes.count == 2)
        #expect(outcomes[0].status == .fail)  // a.py ran and failed
        // b.py auto-failed (not run) with the exact shared skip message.
        #expect(outcomes[1].status == .fail)
        #expect(outcomes[1].shortResult == skippedPrerequisiteMessage(prerequisite: "a.py"))
        #expect(outcomes[1].executionTimeMs == 0)
    }

    @Test func dependencyGateRunsWhenPrerequisitePasses() async {
        let executor = FakeExecutor(outputs: ["a.py": pass(), "b.py": pass()])
        let suites = [
            SuiteItem(script: "a.py", tier: .pub),
            SuiteItem(script: "b.py", tier: .pub, dependsOn: ["a.py"]),
        ]

        let outcomes = await executeSuites(
            suites, timeLimitSeconds: 10, attemptNumber: 1, executor: executor)

        #expect(outcomes.count == 2)
        #expect(outcomes.allSatisfy { $0.status == .pass })
        #expect(outcomes[1].shortResult != skippedPrerequisiteMessage(prerequisite: "a.py"))
    }

    @Test func missingScriptEmitsNoOutcomeButFiresEvent() async {
        let executor = FakeExecutor(outputs: ["present.py": pass()])
        let log = EventLog()
        let suites = [
            SuiteItem(script: "ghost.py", tier: .pub),
            SuiteItem(script: "present.py", tier: .pub),
        ]

        let outcomes = await executeSuites(
            suites, timeLimitSeconds: 10, attemptNumber: 1, executor: executor,
            onEvent: { log.record($0) })

        // Only the present script yields an outcome.
        #expect(outcomes.count == 1)
        #expect(outcomes[0].testName == "present")

        let missing = log.events.contains {
            if case .missingScript(let s) = $0 { return s == "ghost.py" }
            return false
        }
        #expect(missing)
    }

    @Test func explicitDisplayNameWinsOverStemButBlankFallsBack() async {
        let executor = FakeExecutor(outputs: ["x.py": pass(), "y.py": pass()])
        let suites = [
            SuiteItem(script: "x.py", tier: .pub, displayName: "Friendly Name"),
            SuiteItem(script: "y.py", tier: .pub, displayName: "   "),  // blank -> stem
        ]

        let outcomes = await executeSuites(
            suites, timeLimitSeconds: 10, attemptNumber: 1, executor: executor)

        #expect(outcomes[0].testName == "Friendly Name")
        #expect(outcomes[1].testName == "y")
    }

    @Test func laterAttemptNeverCountsAsFirstPass() async {
        let executor = FakeExecutor(outputs: ["t.py": pass()])
        let outcomes = await executeSuites(
            [SuiteItem(script: "t.py", tier: .pub)],
            timeLimitSeconds: 10, attemptNumber: 3, executor: executor)

        #expect(outcomes[0].status == .pass)
        #expect(outcomes[0].attemptNumber == 3)
        #expect(outcomes[0].isFirstPassSuccess == false)
    }

    // MARK: - The event stream
    //
    // These exist because a mutation run deleted `onEvent(.willRun(…))` and
    // `onEvent(.didFinish(…))` from the loop and NOTHING failed: the suite
    // asserted only the returned outcomes, and the events are a separate
    // output. They are not decoration — `RunnerDaemon+JobProcessing` turns them
    // into the `test_execution_start` / `test_execution_end` / `timeout`
    // structured log events that `docs/operational-diagnostics.md` documents,
    // so losing one blinds the runner's observability without touching a mark.
    //
    // `missingScript` was already covered; the other two were not.

    @Test func emitsWillRunAndDidFinishAroundEveryScriptThatRuns() async {
        let executor = FakeExecutor(outputs: ["a.py": pass(5), "b.py": fail()])
        let log = EventLog()

        _ = await executeSuites(
            [SuiteItem(script: "a.py", tier: .pub), SuiteItem(script: "b.py", tier: .pub)],
            timeLimitSeconds: 10, attemptNumber: 1, executor: executor,
            onEvent: { log.record($0) })

        // Order matters: `willRun` must precede its script's `didFinish`, which
        // is what makes the two log events bracket one execution.
        #expect(
            log.events.map(describe) == [
                "willRun(a.py)",
                "didFinish(a.py, pass, timedOut: false)",
                "willRun(b.py)",
                "didFinish(b.py, fail, timedOut: false)",
            ])
    }

    @Test func didFinishCarriesTheTimedOutFlagThatDrivesTheTimeoutLogEvent() async {
        let killed = ScriptOutput(
            exitCode: -1, stdout: "", stderr: "still running when killed",
            executionTimeMs: 10_000, timedOut: true)
        let log = EventLog()

        _ = await executeSuites(
            [SuiteItem(script: "slow.py", tier: .pub)],
            timeLimitSeconds: 10, attemptNumber: 1, executor: FakeExecutor(outputs: ["slow.py": killed]),
            onEvent: { log.record($0) })

        #expect(
            log.events.map(describe) == [
                "willRun(slow.py)",
                "didFinish(slow.py, timeout, timedOut: true)",
            ])
    }

    @Test func aScriptSkippedByItsPrerequisiteFiresNoEvents() async {
        // The dependency gate `continue`s before both emissions, so a skipped
        // script must not look like an execution in the log.
        let executor = FakeExecutor(outputs: ["a.py": fail(), "b.py": pass()])
        let log = EventLog()

        _ = await executeSuites(
            [
                SuiteItem(script: "a.py", tier: .pub),
                SuiteItem(script: "b.py", tier: .pub, dependsOn: ["a.py"]),
            ],
            timeLimitSeconds: 10, attemptNumber: 1, executor: executor,
            onEvent: { log.record($0) })

        #expect(
            log.events.map(describe) == [
                "willRun(a.py)",
                "didFinish(a.py, fail, timedOut: false)",
            ])
    }
}
