import JavaScriptEventLoop
import JavaScriptKit
import RunnerCore

// Bridge Swift Concurrency to the JS microtask loop so `executeSuites` (async)
// can run in a Task and await JS Promises (Pyodide runs) — required before any
// `JSPromise.async { … }` body or `await promise.value` executes.
JavaScriptEventLoop.installGlobalExecutor()

// Embedded-Swift bridge over the pure RunnerCore extractor. Registers a single
// JS-callable global, marshalling cells in / result out via JavaScriptKit JS
// values — no Foundation, no BridgeJS (both incompatible with Embedded Swift).
//
// Exposed to JS as `globalThis.runnerExtractPython(cells, filename)`:
//   cells    — array of { cell_type: string, source: string }
//   filename — string
//   returns  — { executableModule, introspectableSource, codeCellCount }
//
// Built for wasm only via scripts/build-runner-wasm.sh (Embedded Swift SDK).
let runnerExtractPython = JSClosure { args in
    guard let cellsArray = args.first?.object else { return .undefined }
    let filename = args.count > 1 ? (args[1].string ?? "") : ""
    let count = Int(cellsArray.length.number ?? 0)

    var cells: [NotebookCell] = []
    var index = 0
    while index < count {
        if let cellObject = cellsArray[index].object {
            cells.append(
                NotebookCell(
                    cellType: cellObject.cell_type.string ?? "",
                    source: cellObject.source.string ?? ""))
        }
        index += 1
    }

    let extracted = extractPython(cells: cells, filename: filename)

    guard let objectConstructor = JSObject.global.Object.function else { return .undefined }
    let result = objectConstructor.new()
    result.executableModule = .string(extracted.executableModule)
    result.introspectableSource = .string(extracted.introspectableSource)
    result.codeCellCount = .number(Double(extracted.codeCellCount))
    return .object(result)
}

JSObject.global.runnerExtractPython = .object(runnerExtractPython)

// Exposed to JS as `globalThis.runnerClassifyScript(name, source)` → the
// interpreter raw value ("python", "sh", "bash", "ruby", …, "unknown"). The
// shared "which interpreter?" decision (RunnerCore.classifyScriptInterpreter),
// so the browser dispatches scripts identically to the native worker.
let runnerClassifyScript = JSClosure { args in
    let name = args.first?.string ?? ""
    let source = args.count > 1 ? (args[1].string ?? "") : ""
    return .string(classifyScriptInterpreter(name: name, source: source).rawValue)
}

JSObject.global.runnerClassifyScript = .object(runnerClassifyScript)

// MARK: - Shared suite-execution loop (Stage 4)
//
// The browser conformance of RunnerCore.ScriptExecutor: it drives the SAME
// `executeSuites` loop the native worker uses (dependency gating, skip messages,
// missing-script handling, and — crucially — `interpretScriptOutput` output
// interpretation), delegating the one substrate-specific operation (running a
// script) back to JS, where browser-runner.js executes it via Pyodide.
//
// Exposed to JS as:
//   globalThis.runnerExecuteSuites(suites, timeLimitSeconds, attemptNumber,
//                                  scriptExists, run) -> Promise<outcome[]>
//   suites        — [{ script, tier, displayName?, dependsOn?, points? }]
//   scriptExists  — (name: string) => boolean            (synchronous)
//   run           — (name: string, timeLimit: number) => Promise<ScriptOutput>
//                   ScriptOutput = { exitCode, stdout, stderr, executionTimeMs, timedOut }
//   resolves to   — [{ testName, testClass, tier, status, shortResult, longResult,
//                      points, executionTimeMs, memoryUsageBytes, attemptNumber,
//                      isFirstPassSuccess }]  (canonical TestOutcome shape)

/// Drives `executeSuites` by delegating to JS callbacks (callable `JSObject`s —
/// not `Sendable`, which is fine here: the wasm package builds in Swift 5
/// language mode with a single-threaded cooperative executor, so no cross-thread
/// send occurs).
struct BrowserScriptExecutor: ScriptExecutor {
    let existsFn: JSObject
    let runFn: JSObject

    func scriptExists(_ name: String) async -> Bool {
        existsFn(name).boolean ?? false
    }

    func run(script: String, timeLimitSeconds: Int) async -> ScriptOutput {
        let returned = runFn(script, Double(timeLimitSeconds))
        // JS may return either a Promise (async Pyodide run) or the result
        // object directly; handle both.
        guard let promise = JSPromise(from: returned) else {
            return scriptOutput(from: returned)
        }
        do {
            return scriptOutput(from: try await promise.value)
        } catch {
            return ScriptOutput(
                exitCode: 2, stdout: "",
                stderr: "browser executor: script run rejected",
                executionTimeMs: 0, timedOut: false)
        }
    }
}

/// Marshal a JS `{ exitCode, stdout, stderr, executionTimeMs, timedOut }` into
/// a `ScriptOutput`. A non-object value is treated as a launch error (exit 2).
private func scriptOutput(from value: JSValue) -> ScriptOutput {
    guard let o = value.object else {
        return ScriptOutput(
            exitCode: 2, stdout: "", stderr: "browser executor: non-object run result",
            executionTimeMs: 0, timedOut: false)
    }
    return ScriptOutput(
        exitCode: Int32(o.exitCode.number ?? 2),
        stdout: o.stdout.string ?? "",
        stderr: o.stderr.string ?? "",
        executionTimeMs: Int(o.executionTimeMs.number ?? 0),
        timedOut: o.timedOut.boolean ?? false)
}

/// Project the JS suite array into `[SuiteItem]` (the runtime view the loop
/// walks). Unknown tiers fall back to `.pub`, matching the JS default.
private func parseSuiteItems(_ array: JSObject) -> [SuiteItem] {
    var items: [SuiteItem] = []
    let count = Int(array.length.number ?? 0)
    var index = 0
    while index < count {
        if let entry = array[index].object {
            let script = entry.script.string ?? ""
            let tier = TestTier(rawValue: entry.tier.string ?? "public") ?? .pub
            let displayName = entry.displayName.string
            let points = Int(entry.points.number ?? 1)
            var dependsOn: [String] = []
            if let deps = entry.dependsOn.object {
                let depCount = Int(deps.length.number ?? 0)
                var depIndex = 0
                while depIndex < depCount {
                    if let dep = deps[depIndex].string { dependsOn.append(dep) }
                    depIndex += 1
                }
            }
            items.append(
                SuiteItem(
                    script: script, tier: tier, displayName: displayName,
                    dependsOn: dependsOn, points: points))
        }
        index += 1
    }
    return items
}

/// Serialize `[TestOutcome]` into a JS array of plain objects.
private func outcomesToJS(_ outcomes: [TestOutcome]) -> JSValue {
    guard let arrayConstructor = JSObject.global.Array.function,
        let objectConstructor = JSObject.global.Object.function
    else { return .undefined }
    let array = arrayConstructor.new()
    for (index, outcome) in outcomes.enumerated() {
        let obj = objectConstructor.new()
        obj.testName = .string(outcome.testName)
        obj.testClass = outcome.testClass.map { JSValue.string($0) } ?? .null
        obj.tier = .string(outcome.tier.rawValue)
        obj.status = .string(outcome.status.rawValue)
        obj.shortResult = .string(outcome.shortResult)
        obj.longResult = outcome.longResult.map { JSValue.string($0) } ?? .null
        obj.points = .number(Double(outcome.points))
        obj.executionTimeMs = .number(Double(outcome.executionTimeMs))
        obj.memoryUsageBytes = outcome.memoryUsageBytes.map { JSValue.number(Double($0)) } ?? .null
        obj.attemptNumber = .number(Double(outcome.attemptNumber))
        obj.isFirstPassSuccess = .boolean(outcome.isFirstPassSuccess)
        array[index] = .object(obj)
    }
    return .object(array)
}

let runnerExecuteSuites = JSClosure { args in
    guard args.count >= 5,
        let suitesArray = args[0].object,
        let existsFn = args[3].object,
        let runFn = args[4].object
    else { return .undefined }

    let timeLimit = Int(args[1].number ?? 10)
    let attempt = Int(args[2].number ?? 1)
    let suites = parseSuiteItems(suitesArray)
    let executor = BrowserScriptExecutor(existsFn: existsFn, runFn: runFn)

    let promise = JSPromise.async {
        let outcomes = await executeSuites(
            suites,
            timeLimitSeconds: timeLimit,
            attemptNumber: attempt,
            executor: executor)
        return outcomesToJS(outcomes)
    }
    return promise.jsValue
}

JSObject.global.runnerExecuteSuites = .object(runnerExecuteSuites)
