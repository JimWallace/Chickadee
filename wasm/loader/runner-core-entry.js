// The vendored loader's entry point (scripts/build-runner-wasm.sh bundles this
// with esbuild into Public/runner-wasm/runner-core.js).
//
// PackageToJS's `init()` instantiates the wasm and returns the BridgeJS
// `exports` — the typed surface declared in wasm/Sources/RunnerWasm/Bridge.swift
// and described by the generated bridge-js.d.ts. This file re-exports that
// `init()` and, once it resolves, registers the legacy `globalThis.runner*`
// entry points on top of the typed exports, so browser-runner.js and the Node
// harnesses keep their contract unchanged.
//
// It is the ONE place that knows both shapes. Three of the old bridge's
// tolerances live here now, since a typed export cannot absorb them:
//   * a Jupyter cell says `cell_type`; the struct field is `cellType`;
//   * a suite entry may omit `displayName` / `dependsOn` / `points`;
//   * a `run` callback may resolve with a partial object, or reject — the old
//     bridge turned both into an exit-2 "error" outcome rather than failing
//     the whole suite, and browser-runner.js relies on the rejection text.
import { init as initBridge } from '../.build/plugins/PackageToJS/outputs/Package/index.js';

const REJECTED_RUN_STDERR = 'browser executor: script run rejected';
const NON_OBJECT_RUN_STDERR = 'browser executor: non-object run result';

function toCells(cells) {
    return (Array.isArray(cells) ? cells : []).map((cell) => ({
        cellType: String(cell?.cell_type ?? cell?.cellType ?? ''),
        source: String(cell?.source ?? ''),
    }));
}

function toSuiteItems(suites) {
    return (Array.isArray(suites) ? suites : []).map((entry) => ({
        script: String(entry?.script ?? ''),
        tier: String(entry?.tier ?? 'public'),
        displayName: typeof entry?.displayName === 'string' ? entry.displayName : null,
        dependsOn: Array.isArray(entry?.dependsOn) ? entry.dependsOn.map(String) : [],
        points: typeof entry?.points === 'number' ? entry.points : 1,
    }));
}

function toScriptOutput(value, fallbackStderr) {
    if (value === null || typeof value !== 'object') {
        return { exitCode: 2, stdout: '', stderr: fallbackStderr, executionTimeMs: 0, timedOut: false };
    }
    return {
        exitCode: typeof value.exitCode === 'number' ? value.exitCode : 2,
        stdout: typeof value.stdout === 'string' ? value.stdout : '',
        stderr: typeof value.stderr === 'string' ? value.stderr : '',
        executionTimeMs: typeof value.executionTimeMs === 'number' ? value.executionTimeMs : 0,
        timedOut: value.timedOut === true,
    };
}

/**
 * Register the legacy `runner*` globals over the typed BridgeJS exports.
 * Exported so a harness can wire the adapters onto its own object.
 */
export function registerLegacyGlobals(exports, target = globalThis) {
    target.runnerExtractPython = (cells, filename) =>
        exports.extractPython(toCells(cells), String(filename ?? ''));
    target.runnerExtractR = (cells, filename) =>
        exports.extractR(toCells(cells), String(filename ?? ''));
    target.runnerExtractLua = (cells, filename) =>
        exports.extractLua(toCells(cells), String(filename ?? ''));
    target.runnerExtractOctave = (cells, filename) =>
        exports.extractOctave(toCells(cells), String(filename ?? ''));
    target.runnerClassifyScript = (name, source) =>
        exports.classifyScript(String(name ?? ''), String(source ?? ''));
    target.runnerExecuteSuites = (suites, timeLimitSeconds, attemptNumber, scriptExists, run) =>
        exports.executeSuites(
            toSuiteItems(suites),
            typeof timeLimitSeconds === 'number' ? timeLimitSeconds : 10,
            typeof attemptNumber === 'number' ? attemptNumber : 1,
            (name) => Boolean(scriptExists(name)),
            async (name, limit) => {
                let result;
                try {
                    result = await run(name, limit);
                } catch (_) {
                    return toScriptOutput(null, REJECTED_RUN_STDERR);
                }
                return toScriptOutput(result, NON_OBJECT_RUN_STDERR);
            });
    return target;
}

/** Instantiate the wasm, register the legacy globals, and return PackageToJS's result. */
export async function init(options) {
    const result = await initBridge(options);
    registerLegacyGlobals(result.exports);
    return result;
}
