// Public/lua-grading-worker.js
//
// The Lua browser-grading substrate: boots the vendored xeus-lua kernel in a
// Web Worker and grades one Lua test script per request.
//
// What this is NOT: a grading implementation.  RunnerCore (Swift, the same
// code the native worker runs, compiled to wasm) owns the suite loop,
// dependency gating, and output interpretation.  The worker protocol, the boot
// sequence and the error handling are `serveGradingWorker` in
// xeus-kernel-shared.js, shared with the other three graders.  This file is
// the part only Lua can supply.
//
// Split of responsibilities:
//   /vendor/xeus-bootstrap.js  — the mambajs slice that unpacks a conda env
//   /xeus-kernel-shared.js     — booting a kernel, driving one cell, the protocol
//   /grading-shared.js         — the emscripten-FS file writer, shared with the others
//   /lua-grading-shared.js     — the Lua wrapper and its reply parsing
//   this file                  — the Lua config
//
// The worker's own ?v= cache-buster is forwarded to every Chickadee-authored
// file it pulls in, so one release's grading files pin together. The kernel's
// own assets under /jupyterlite/xeus/ are not busted: they are regenerated only
// by a deliberate re-vendor, and the editor loads them unbusted too.

var _search = self.location.search || '';
importScripts('/vendor/xeus-bootstrap.js' + _search);
importScripts('/xeus-kernel-shared.js' + _search);
importScripts('/grading-shared.js' + _search);
importScripts('/lua-grading-shared.js' + _search);

var _lua = self.ChickadeeLuaGradingShared;

self.ChickadeeXeusKernel.serveGradingWorker({
    label: 'Lua',
    phasePrefix: 'lua',
    // No `bootSeeds`: every package in this env is in xeus-lua's own closure,
    // so booting a subset would select all of them. See the note beside
    // LUA_KERNEL.
    kernel: _lua.LUA_KERNEL,
    // The harness gives package.path a cwd-relative entry, so `require` finds
    // the workspace's modules.
    harness: { source: _lua.SETUP_LUA, what: 'the Lua grading harness failed to install' },
    seedCell: _lua.assignmentSeedLua,
    makeNonce: _lua.makeNonce,
    runScript: _lua.runScriptLua,
    parseRunOutput: _lua.parseRunOutput,
    // The on-demand install is wired up even though the vendored env has
    // nothing to install: emscripten-forge carries no Lua library packages, so
    // `packageForModule` always answers null and the retry makes one pass that
    // returns the original failure untouched.  That is what a student's
    // `require` typo needs, and if Lua packages ever appear on the channel,
    // this is already correct.
    missingPackage: {
        // `module 'foo' not found:` → foo.  Lua words this identically for
        // `require` however it is reached, and the following "no file ..."
        // lines are the search path rather than another name.  Lua module
        // names may contain dots (`a.b` maps to `a/b.lua`) and underscores.
        pattern: /module ['‘"]([A-Za-z_][A-Za-z0-9_.-]*)['’"] not found/,
        // The wrapper writes an uncaught error to the kernel's stderr stream
        // itself, so a failed require lands there; `failure` covers the case
        // where the wrapper never ran at all.
        textOf: function (reply) { return reply.stderr || reply.failure; },
    },
});
