// Public/r-grading-worker.js
//
// The R browser-grading substrate: boots the vendored xeus-r kernel in a Web
// Worker and grades one R test script per request.
//
// This is what makes browser-graded R possible at all.  WebR was never viable
// (jupyterlite-webr caps at jupyterlite-core<0.7 and we pin 0.8.x), so before
// this R could only be graded by the native worker.  The kernel is the SAME
// `chickadee-r` env the notebook editor boots for R notebooks, so for R "runs
// in the editor" and "runs in the grader" mean one environment and a missing
// package shows up at authoring time.
//
// What this is NOT: a grading implementation.  RunnerCore (Swift, the same
// code the native worker runs, compiled to wasm) owns the suite loop,
// dependency gating, and output interpretation.  The worker protocol, the boot
// sequence and the error handling are `serveGradingWorker` in
// xeus-kernel-shared.js, shared with the other three graders.  This file is
// the part only R can supply.
//
// Split of responsibilities:
//   /vendor/xeus-bootstrap.js  — the mambajs slice that unpacks a conda env
//   /xeus-kernel-shared.js     — booting a kernel, driving one cell, the protocol
//   /grading-shared.js         — the emscripten-FS file writer, shared with the others
//   /r-grading-shared.js       — the R wrapper and its reply parsing
//   this file                  — the R config
//
// The worker's own ?v= cache-buster is forwarded to every Chickadee-authored
// file it pulls in, so one release's grading files pin together. The kernel's
// own assets under /jupyterlite/xeus/ are not busted: they are regenerated only
// by a deliberate re-vendor, and the editor loads them unbusted too.

var _search = self.location.search || '';
importScripts('/vendor/xeus-bootstrap.js' + _search);
importScripts('/xeus-kernel-shared.js' + _search);
importScripts('/grading-shared.js' + _search);
importScripts('/r-grading-shared.js' + _search);

var _r = self.ChickadeeRGradingShared;

self.ChickadeeXeusKernel.serveGradingWorker({
    label: 'R',
    phasePrefix: 'r',
    // The kernel boots with base R only (`R_KERNEL.bootSeeds`); the tidyverse
    // is 22.2 MB of the 62.1 and is installed when a script attaches
    // something.  See the bootSeeds comment in r-grading-shared.js.
    kernel: _r.R_KERNEL,
    seedCell: _r.assignmentSeedR,
    makeNonce: _r.makeNonce,
    runScript: _r.runScriptR,
    parseRunOutput: _r.parseRunOutput,
    // R needs no post-install step: `library()` re-reads .libPaths() every
    // call, so a package that has just landed is found.
    //
    // Re-running a script after each install is cheap despite R's very
    // expensive first attach (dplyr is ~26 s, and it pays for the whole shared
    // tidyverse dependency graph): attaching a package that is ALREADY attached
    // in this session is instant, so a re-run pays only for the newly
    // installed one.
    missingPackage: {
        // `there is no package called 'dplyr'` → dplyr.  R words this
        // identically whether the script said `library(dplyr)`,
        // `require(dplyr)` or `dplyr::f()`, so one pattern covers every way a
        // script can name a package.  R package names allow dots
        // (`data.table`); underscores are NOT legal and are deliberately
        // excluded, the same reasoning RLibraryScanner uses.
        pattern: /there is no package called ['‘"]([A-Za-z][A-Za-z0-9.]*)['’"]/,
        // evaluate's calling handlers put every message()/warning()/error on
        // the kernel's stderr stream, so a failed attach lands there whether
        // or not the wrapper managed to report.
        textOf: function (reply, parsed) {
            return reply.stderr || (parsed ? parsed.stdout : '') || reply.failure;
        },
    },
});
