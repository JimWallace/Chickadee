// Type declarations for `tsc -p jsconfig.json` (#2782). Not served.
//
// Public/runner-wasm/runner-core.js is the esbuild bundle of the RunnerCore
// wasm loader (wasm/loader/runner-core-entry.js), built by
// scripts/build-runner-wasm.sh. Public/browser-runner.js imports it by its
// served path, `/runner-wasm/runner-core.js`, so the `paths` entry in
// jsconfig.json maps it to this file, as for vendor-codemirror.d.ts.
//
// Public/runner-wasm/runner-core.d.ts beside the bundle is not this module:
// BridgeJS generates it for the typed wasm exports, which the loader wraps.
//
// `init` instantiates the wasm and registers the `globalThis.runner*` entry
// points. Its result is `any`, like the globals in chickadee-globals.d.ts.
export declare function init(options?: any): Promise<any>;
export declare function registerLegacyGlobals(exports: any, target?: any): any;
