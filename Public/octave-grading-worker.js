// Public/octave-grading-worker.js
//
// The Octave browser-grading substrate: boots the vendored xeus-octave kernel
// in a Web Worker and grades one Octave test script per request.  Sibling of
// Public/r-grading-worker.js, Public/python-grading-worker.js and
// Public/lua-grading-worker.js.
//
// What this is NOT: a fourth grading implementation.  RunnerCore (Swift, the
// same code the native worker runs, compiled to wasm) still owns the suite
// loop, dependency gating, and output interpretation.  This worker supplies
// one operation — run a script, report its raw exit code + stdout + stderr —
// which is exactly the seam `ScriptExecutor` was carved out for.
//
// Split of responsibilities:
//   /vendor/xeus-bootstrap.js    — the mambajs slice that unpacks a conda env
//   /xeus-kernel-shared.js       — booting a kernel + driving one cell (any kernel)
//   /grading-shared.js           — the emscripten-FS file writer, shared with the others
//   /octave-grading-shared.js    — the Octave wrapper and its reply parsing
//   this file                    — the worker protocol
//
// Protocol (identical in shape to the other three graders; every reply
// carries the originating `id`):
//   { id, type: 'init', files: { <relativePath>: <string | number[]> }, seed }
//     → boot the kernel, install the wrapper harness, materialize the file map
//       into a fresh work dir, chdir there, and set CHICKADEE_ASSIGNMENT_SEED
//       when `seed` is non-null
//     → posts back { id, ok: true }  (or { id, ok: false, error })
//   { id, type: 'run', script: <name>, limit: <seconds> }
//     → grade one script, capturing its stdout/stderr and exit code
//     → posts back { id, ok: true, result: { exitCode, stdout, stderr } }
//                or { id, ok: false, error }
//
// As with the other graders there is NO timeout here: the main thread races
// the reply against a real timer and calls Worker.terminate() to kill
// run-away student code, which is the only kill path that works against a
// synchronous CPU-bound loop.
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

var _kernel = self.ChickadeeXeusKernel;
var _shared = self.ChickadeeGradingShared;
var _octave = self.ChickadeeOctaveGradingShared;
var _reply = _kernel.reply;

// `package X is not installed` → X, the shape `pkg load` errors in.  The
// chickadee-octave inventory is empty (emscripten-forge carries no Octave
// Forge packages), so `packageForModule` always answers null and the retry
// loop makes one pass and lets the original error stand — the behaviour a
// student's typo needs, proven rather than assumed by the smoke fixture.  If
// Forge packages ever appear on the channel, this is already correct.
var MISSING_OCTAVE_PACKAGE = /package ['‘"]?([A-Za-z0-9][A-Za-z0-9_.-]*)['’"]? is not installed/;

// Grade one Octave script and return RAW output { exitCode, stdout, stderr }.
// No interpretation happens here — RunnerCore maps the exit code to a status
// and reads the last stdout line for the shortResult, byte-for-byte as it
// does for the native `octave-cli` subprocess.
async function runOctaveScript(scriptName) {
    var parsed = null;
    var reply = await _kernel.runInstallingMissingPackages(
        async function () {
            var nonce = _octave.makeNonce();
            var attemptReply = await _kernel.execute(_octave.runScriptOctave(scriptName, nonce));
            parsed = _octave.parseRunOutput(attemptReply.stdout, nonce);
            return attemptReply;
        },
        {
            pattern: MISSING_OCTAVE_PACKAGE,
            // The wrapper writes an uncaught error to the kernel's stderr
            // stream itself, so a failed `pkg load` lands there; `failure`
            // covers the case where the wrapper never ran at all.
            textOf: function (r) { return r.stderr || r.failure; },
            onInstall: function (added) {
                _reply({
                    type: 'phase', phase: 'octave_package_installed', packages: added.join(','),
                });
            },
        });
    if (parsed) {
        // stdout is everything the kernel published before the wrapper's
        // status line; stderr is whatever the cell published on the kernel's
        // stderr stream, which is where the wrapper puts an uncaught error's
        // message — see the octave-grading-shared.js header.
        return { exitCode: parsed.exitCode, stdout: parsed.stdout, stderr: reply.stderr || '' };
    }
    // The wrapper never reported. Surface it as a substrate error (exit 2)
    // with whatever the kernel did say, rather than inventing a pass/fail.
    var detail = reply.failure || (reply.stderr || '').trim()
        || 'the Octave kernel produced no result for this test';
    return { exitCode: 2, stdout: 'Octave grading failed: ' + detail, stderr: reply.stderr || '' };
}

self.onmessage = async function (e) {
    var msg = e.data || {};
    var id = msg.id;
    try {
        if (msg.type === 'init') {
            var initT0 = Date.now();
            // No `seeds`: every package in this env is in xeus-octave's own
            // closure, so booting a subset would select all of them. See the
            // note beside OCTAVE_KERNEL.
            await _kernel.boot(_octave.OCTAVE_KERNEL);
            // Breadcrumb (no `id`) — the kernel boot is the slow step (the
            // largest env of the four), so a wedge here is worth telling apart
            // from a wedge in file setup. browser-runner.js forwards these to
            // the submit-phase telemetry.
            _reply({ type: 'phase', phase: 'octave_kernel_booted', ms: Date.now() - initT0 });
            var setup = await _kernel.execute(_octave.SETUP_OCTAVE);
            if (setup.failure) {
                throw new Error('the Octave grading harness failed to install: ' + setup.failure);
            }
            _kernel.mountWorkspace(
                '/chickadee_work_' + Date.now(), msg.files, _shared.writeFilesToEmscriptenFS);
            if (msg.seed !== null && msg.seed !== undefined) {
                await _kernel.execute(_octave.assignmentSeedOctave(msg.seed));
            }
            _reply({ type: 'phase', phase: 'octave_env_configured', ms: Date.now() - initT0 });
            _reply({ id: id, ok: true });
            return;
        }
        if (msg.type === 'run') {
            var result = await runOctaveScript(msg.script);
            _reply({ id: id, ok: true, result: result });
            return;
        }
        _reply({ id: id, ok: false, error: 'unknown message type: ' + msg.type });
    } catch (err) {
        _reply({ id: id, ok: false, error: (err && err.message) ? String(err.message) : String(err) });
    }
};
