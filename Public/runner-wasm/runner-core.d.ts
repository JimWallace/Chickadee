// NOTICE: This is auto-generated code by BridgeJS from JavaScriptKit,
// DO NOT EDIT.
//
// To update this file, just rebuild your project or run
// `swift package bridge-js`.

/**
 * One notebook cell as JS hands it over: `{ cellType, source }`.
 */
export interface JSNotebookCell {
    cellType: string;
    source: string;
}
/**
 * `extractPython`'s two views of a notebook plus the kept-cell count.
 */
export interface JSExtractedPython {
    executableModule: string;
    introspectableSource: string;
    codeCellCount: number;
}
/**
 * The marker-based extractions (R, Lua, Octave): one flattened source file.
 */
export interface JSExtractedSource {
    source: string;
    codeCellCount: number;
}
/**
 * One manifest entry, as browser-runner.js projects it.
 */
export interface JSSuiteItem {
    script: string;
    /**
     * A `TestTier` raw value; an unknown tier falls back to `public`.
     */
    tier: string;
    displayName: string | null;
    dependsOn: string[];
    points: number;
}
/**
 * What the JS `run` callback resolves with for one script.
 */
export interface JSScriptOutput {
    exitCode: number;
    stdout: string;
    stderr: string;
    executionTimeMs: number;
    timedOut: boolean;
}
/**
 * The canonical `TestOutcome` shape, field for field, with the enums as
 * their raw strings — what the browser POSTs and the server decodes.
 */
export interface JSTestOutcome {
    testName: string;
    testClass: string | null;
    tier: string;
    status: string;
    shortResult: string;
    longResult: string | null;
    score: number;
    points: number;
    metric: number | null;
    executionTimeMs: number;
    memoryUsageBytes: number | null;
    attemptNumber: number;
    isFirstPassSuccess: boolean;
}
export type Exports = {
    /**
     * `extractPython(cells, filename)`: the resilient `exec(compile())` module
     * and the introspectable source, from RunnerCore's one implementation.
     */
    extractPython(cells: JSNotebookCell[], filename: string): JSExtractedPython;
    /**
     * `extractR(cells, filename)`: the marker-emitting extraction the native
     * worker runs, so a browser-extracted `.R` file is byte-identical.
     */
    extractR(cells: JSNotebookCell[], filename: string): JSExtractedSource;
    /**
     * `extractLua(cells, filename)`: the same extraction with a `--` leader.
     */
    extractLua(cells: JSNotebookCell[], filename: string): JSExtractedSource;
    /**
     * `extractOctave(cells, filename)`: the same extraction with a `%` leader.
     */
    extractOctave(cells: JSNotebookCell[], filename: string): JSExtractedSource;
    /**
     * `classifyScript(name, source)`: the interpreter raw value ("python", "sh",
     * "rscript", …, "unknown") from the shared decision the native worker uses.
     */
    classifyScript(name: string, source: string): string;
    /**
     * `executeSuites(suites, timeLimitSeconds, attemptNumber, scriptExists, run)`:
     * drives RunnerCore's `executeSuites` — the SAME loop the native worker runs —
     * and resolves with one canonical outcome per executed-or-skipped entry.
     */
    executeSuites(suites: JSSuiteItem[], timeLimitSeconds: number, attemptNumber: number, scriptExists: (arg0: string) => boolean, run: (arg0: string, arg1: number) => Promise<JSScriptOutput>): Promise<JSTestOutcome[]>;
    JSExtractedPython: {
        init(executableModule: string, introspectableSource: string, codeCellCount: number): JSExtractedPython;
    },
    JSExtractedSource: {
        init(source: string, codeCellCount: number): JSExtractedSource;
    },
    JSNotebookCell: {
        init(cellType: string, source: string): JSNotebookCell;
    },
    JSScriptOutput: {
        init(exitCode: number, stdout: string, stderr: string, executionTimeMs: number, timedOut: boolean): JSScriptOutput;
    },
    JSSuiteItem: {
        init(script: string, tier: string, displayName: string | null, dependsOn: string[], points: number): JSSuiteItem;
    },
    JSTestOutcome: {
        init(testName: string, testClass: string | null, tier: string, status: string, shortResult: string, longResult: string | null, score: number, points: number, metric: number | null, executionTimeMs: number, memoryUsageBytes: number | null, attemptNumber: number, isFirstPassSuccess: boolean): JSTestOutcome;
    },
}
export type Imports = {
}
export function createInstantiator(options: {
    imports: Imports;
}, swift: any): Promise<{
    addImports: (importObject: WebAssembly.Imports) => void;
    setInstance: (instance: WebAssembly.Instance) => void;
    createExports: (instance: WebAssembly.Instance) => Exports;
}>;