// RunnerWasm/Bridge.swift
//
// The typed JS surface of the browser grading wasm, declared with BridgeJS
// `@JS` and compiled by the BridgeJS build plugin into `bridge-js.js` /
// `bridge-js.d.ts`. Every value crosses the boundary as a declared struct,
// string, number, bool, array or optional; nothing here reads a `JSValue`.
//
// This replaced a hand-marshalled bridge — five `JSClosure`s reading untyped
// `JSObject` properties with `?? ""` / `?? 0` defaults and writing results
// property by property — that existed because BridgeJS did not build under
// Embedded Swift when it was written. It does now (JavaScriptKit 0.59 on the
// Swift 6.4 Embedded SDK), so the contract is the generated `.d.ts` rather
// than a comment, and the marshalling code is gone.
//
// The `JS`-prefixed structs are the boundary's own types, kept separate from
// RunnerCore's (`NotebookCell`, `SuiteItem`, `ScriptOutput`, `TestOutcome`)
// for two reasons: a `@JS` struct needs a public memberwise init the RunnerCore
// types do not expose, and RunnerCore's enums (`TestTier`, `TestStatus`) cross
// as their raw strings, exactly as the old bridge sent them.
//
// The legacy `globalThis.runner*` entry points that browser-runner.js and the
// Node harnesses call are provided by `wasm/loader/runner-core-entry.js`, a
// small JS adapter over these exports (it also maps a Jupyter cell's
// `cell_type` onto `cellType`). Built for wasm only via
// scripts/build-runner-wasm.sh.

import JavaScriptKit
import RunnerCore

// MARK: - Notebook extraction

/// One notebook cell as JS hands it over: `{ cellType, source }`.
@JS public struct JSNotebookCell {
    public var cellType: String
    public var source: String

    @JS public init(cellType: String, source: String) {
        self.cellType = cellType
        self.source = source
    }
}

/// `extractPython`'s two views of a notebook plus the kept-cell count.
@JS public struct JSExtractedPython {
    public var executableModule: String
    public var introspectableSource: String
    public var codeCellCount: Int

    @JS public init(executableModule: String, introspectableSource: String, codeCellCount: Int) {
        self.executableModule = executableModule
        self.introspectableSource = introspectableSource
        self.codeCellCount = codeCellCount
    }
}

/// The marker-based extractions (R, Lua, Octave): one flattened source file.
@JS public struct JSExtractedSource {
    public var source: String
    public var codeCellCount: Int

    @JS public init(source: String, codeCellCount: Int) {
        self.source = source
        self.codeCellCount = codeCellCount
    }
}

private func notebookCells(_ cells: [JSNotebookCell]) -> [NotebookCell] {
    cells.map { NotebookCell(cellType: $0.cellType, source: $0.source) }
}

private func extractedSource(_ extracted: ExtractedRNotebook) -> JSExtractedSource {
    JSExtractedSource(source: extracted.source, codeCellCount: extracted.codeCellCount)
}

/// `extractPython(cells, filename)`: the resilient `exec(compile())` module
/// and the introspectable source, from RunnerCore's one implementation.
@JS("extractPython")
public func bridgeExtractPython(cells: [JSNotebookCell], filename: String) -> JSExtractedPython {
    let extracted = extractPython(cells: notebookCells(cells), filename: filename)
    return JSExtractedPython(
        executableModule: extracted.executableModule,
        introspectableSource: extracted.introspectableSource,
        codeCellCount: extracted.codeCellCount)
}

/// `extractR(cells, filename)`: the marker-emitting extraction the native
/// worker runs, so a browser-extracted `.R` file is byte-identical.
@JS("extractR")
public func bridgeExtractR(cells: [JSNotebookCell], filename: String) -> JSExtractedSource {
    extractedSource(extractR(cells: notebookCells(cells), filename: filename))
}

/// `extractLua(cells, filename)`: the same extraction with a `--` leader.
@JS("extractLua")
public func bridgeExtractLua(cells: [JSNotebookCell], filename: String) -> JSExtractedSource {
    extractedSource(extractLua(cells: notebookCells(cells), filename: filename))
}

/// `extractOctave(cells, filename)`: the same extraction with a `%` leader.
@JS("extractOctave")
public func bridgeExtractOctave(cells: [JSNotebookCell], filename: String) -> JSExtractedSource {
    extractedSource(extractOctave(cells: notebookCells(cells), filename: filename))
}

// MARK: - Script classification

/// `classifyScript(name, source)`: the interpreter raw value ("python", "sh",
/// "rscript", …, "unknown") from the shared decision the native worker uses.
@JS("classifyScript")
public func bridgeClassifyScript(name: String, source: String) -> String {
    classifyScriptInterpreter(name: name, source: source).rawValue
}

// MARK: - Suite execution

/// One manifest entry, as browser-runner.js projects it.
@JS public struct JSSuiteItem {
    public var script: String
    /// A `TestTier` raw value; an unknown tier falls back to `public`.
    public var tier: String
    public var displayName: String?
    public var dependsOn: [String]
    public var points: Int

    @JS public init(script: String, tier: String, displayName: String?, dependsOn: [String], points: Int) {
        self.script = script
        self.tier = tier
        self.displayName = displayName
        self.dependsOn = dependsOn
        self.points = points
    }
}

/// What the JS `run` callback resolves with for one script.
@JS public struct JSScriptOutput {
    public var exitCode: Int
    public var stdout: String
    public var stderr: String
    public var executionTimeMs: Int
    public var timedOut: Bool

    @JS public init(exitCode: Int, stdout: String, stderr: String, executionTimeMs: Int, timedOut: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.executionTimeMs = executionTimeMs
        self.timedOut = timedOut
    }
}

/// The canonical `TestOutcome` shape, field for field, with the enums as
/// their raw strings — what the browser POSTs and the server decodes.
@JS public struct JSTestOutcome {
    public var testName: String
    public var testClass: String?
    public var tier: String
    public var status: String
    public var shortResult: String
    public var longResult: String?
    public var score: Double
    public var points: Int
    public var metric: Double?
    public var executionTimeMs: Int
    public var memoryUsageBytes: Int?
    public var attemptNumber: Int
    public var isFirstPassSuccess: Bool

    @JS public init(
        testName: String, testClass: String?, tier: String, status: String, shortResult: String,
        longResult: String?, score: Double, points: Int, metric: Double?, executionTimeMs: Int,
        memoryUsageBytes: Int?, attemptNumber: Int, isFirstPassSuccess: Bool
    ) {
        self.testName = testName
        self.testClass = testClass
        self.tier = tier
        self.status = status
        self.shortResult = shortResult
        self.longResult = longResult
        self.score = score
        self.points = points
        self.metric = metric
        self.executionTimeMs = executionTimeMs
        self.memoryUsageBytes = memoryUsageBytes
        self.attemptNumber = attemptNumber
        self.isFirstPassSuccess = isFirstPassSuccess
    }

    init(_ outcome: TestOutcome) {
        self.init(
            testName: outcome.testName, testClass: outcome.testClass, tier: outcome.tier.rawValue,
            status: outcome.status.rawValue, shortResult: outcome.shortResult,
            longResult: outcome.longResult, score: outcome.score, points: outcome.points,
            metric: outcome.metric, executionTimeMs: outcome.executionTimeMs,
            memoryUsageBytes: outcome.memoryUsageBytes, attemptNumber: outcome.attemptNumber,
            isFirstPassSuccess: outcome.isFirstPassSuccess)
    }
}

/// The browser conformance of RunnerCore's `ScriptExecutor`: the one
/// substrate-specific operation, running a script, is delegated to the JS
/// callbacks; everything else (dependency gating, skip messages, missing-script
/// handling, `interpretScriptOutput`) is the shared loop. The closures are
/// JS functions and not `Sendable`; the wasm package builds in Swift 5 mode on
/// a single-threaded cooperative executor, so nothing is sent across threads.
private struct BrowserScriptExecutor: ScriptExecutor {
    let exists: (String) -> Bool
    let runScript: (String, Int) async -> JSScriptOutput

    func scriptExists(_ name: String) async -> Bool {
        exists(name)
    }

    func run(script: String, timeLimitSeconds: Int) async -> ScriptOutput {
        let output = await runScript(script, timeLimitSeconds)
        return ScriptOutput(
            exitCode: Int32(clamping: output.exitCode),
            stdout: output.stdout,
            stderr: output.stderr,
            executionTimeMs: output.executionTimeMs,
            timedOut: output.timedOut)
    }
}

/// `executeSuites(suites, timeLimitSeconds, attemptNumber, scriptExists, run)`:
/// drives RunnerCore's `executeSuites` — the SAME loop the native worker runs —
/// and resolves with one canonical outcome per executed-or-skipped entry.
@JS("executeSuites")
public func bridgeExecuteSuites(
    suites: [JSSuiteItem],
    timeLimitSeconds: Int,
    attemptNumber: Int,
    scriptExists: @escaping (String) -> Bool,
    run: @escaping (String, Int) async -> JSScriptOutput
) async -> [JSTestOutcome] {
    let items = suites.map { entry in
        SuiteItem(
            script: entry.script,
            tier: TestTier(rawValue: entry.tier) ?? .pub,
            displayName: entry.displayName,
            dependsOn: entry.dependsOn,
            points: entry.points)
    }
    let executor = BrowserScriptExecutor(exists: scriptExists, runScript: run)
    let outcomes = await executeSuites(
        items, timeLimitSeconds: timeLimitSeconds, attemptNumber: attemptNumber, executor: executor)
    return outcomes.map(JSTestOutcome.init)
}
