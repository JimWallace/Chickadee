// Tools/vendor/xeus-bootstrap-entry.mjs
//
// Source-of-truth entry for Public/vendor/xeus-bootstrap.js — the small slice of
// the JupyterLite xeus stack that Chickadee's R grading worker needs to boot the
// vendored `chickadee-r` kernel OUTSIDE JupyterLab.
//
// Why bundle it ourselves rather than reuse Public/jupyterlite/extensions/
// @jupyterlite/xeus-extension: that build is a module-federation bundle. Its
// worker chunks `consume` @jupyterlab/services, @lumino/*, @jupyterlite/services
// and friends from a share scope the JupyterLab application sets up, with
// `import: null` (no fallback) — so loading one in a bare Worker dies in
// __webpack_require__.f.consumes before any kernel code runs. Building the same
// upstream packages from source with esbuild yields a self-contained bundle with
// no federation runtime at all.
//
// The grading worker is a CLASSIC worker (it needs importScripts to pull in the
// kernel's emscripten glue), so this is emitted as an IIFE that publishes one
// global: ChickadeeXeusBootstrap.
//
// Kept deliberately thin — the boot SEQUENCE (locateFile wiring, empack
// bootstrap, xkernel start) lives in Public/r-grading-worker.js, mirroring
// @jupyterlite/xeus's EmpackedXeusRemoteKernel. Only the pieces that would be
// unreasonable to reimplement (unpacking conda tarballs into an emscripten FS)
// are vendored from upstream.

import {
    empackLockToMambajsLock,
    bootstrapEmpackPackedEnvironment,
    loadSharedLibs,
    waitRunDependencies,
} from '@emscripten-forge/mambajs-core';
import { initUntarJS } from '@emscripten-forge/untarjs';

globalThis.ChickadeeXeusBootstrap = {
    empackLockToMambajsLock,
    bootstrapEmpackPackedEnvironment,
    loadSharedLibs,
    waitRunDependencies,
    initUntarJS,
};
