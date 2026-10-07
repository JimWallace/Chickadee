// Public/octave-grading-worker.js
//
// The Octave browser-grading substrate: boots the vendored xeus-octave kernel
// in a Web Worker and grades one Octave test script per request.
//
// What this is NOT: a grading implementation.  RunnerCore (Swift, the same
// code the native worker runs, compiled to wasm) owns the suite loop,
// dependency gating, and output interpretation.  The worker protocol, the boot
// sequence and the error handling are `serveGradingWorker` in
// xeus-kernel-shared.js, shared with the other three graders.  This file is
// the part only Octave can supply.
//
// Split of responsibilities:
//   /vendor/xeus-bootstrap.js    — the mambajs slice that unpacks a conda env
//   /xeus-kernel-shared.js       — booting a kernel, driving one cell, the protocol
//   /grading-shared.js           — the emscripten-FS file writer, shared with the others
//   /octave-grading-shared.js    — the Octave wrapper and its reply parsing
//   this file                    — the Octave config
//
// The worker's own ?v= cache-buster is forwarded to every Chickadee-authored
// file it pulls in, so one release's grading files pin together. The kernel's
// own assets under /jupyterlite/xeus/ are not busted: they are regenerated
// only by a deliberate re-vendor, and the editor loads them unbusted too.

var _search = self.location.search || '';
importScripts('/vendor/xeus-bootstrap.js' + _search);
importScripts('/xeus-kernel-shared.js' + _search);
importScripts('/grading-shared.js' + _search);
importScripts('/octave-grading-shared.js' + _search);

var _octave = self.ChickadeeOctaveGradingShared;

self.ChickadeeXeusKernel.serveGradingWorker({
    label: 'Octave',
    phasePrefix: 'octave',
    // No `bootSeeds`: every package in this env is in xeus-octave's own
    // closure, so booting a subset would select all of them. See the note
    // beside OCTAVE_KERNEL.
    kernel: _octave.OCTAVE_KERNEL,
    harness: { source: _octave.SETUP_OCTAVE, what: 'the Octave grading harness failed to install' },
    seedCell: _octave.assignmentSeedOctave,
    // Puts the working directory back before every script (#2384).
    beforeEachScript: _octave.resetCellOctave,
    makeNonce: _octave.makeNonce,
    runScript: _octave.runScriptOctave,
    parseRunOutput: _octave.parseRunOutput,
    // The chickadee-octave inventory is empty (emscripten-forge carries no
    // Octave Forge packages), so `packageForModule` always answers null and
    // the retry makes one pass and lets the original error stand: the
    // behaviour a student's typo needs, proven by the smoke fixture.  If Forge
    // packages ever appear on the channel, this is already correct.
    missingPackage: {
        // `package X is not installed` → X, the shape `pkg load` errors in.
        pattern: /package ['‘"]?([A-Za-z0-9][A-Za-z0-9_.-]*)['’"]? is not installed/,
        // The wrapper writes an uncaught error to the kernel's stderr stream
        // itself, so a failed `pkg load` lands there; `failure` covers the
        // case where the wrapper never ran at all.
        textOf: function (reply) { return reply.stderr || reply.failure; },
    },
});
