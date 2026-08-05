// Public/r-grading-worker.js
//
// The R browser-grading substrate: boots the vendored xeus-r kernel in a Web
// Worker and grades one R test script per request.  Sibling of
// Public/python-grading-worker.js, which does the same for xeus-python.
//
// This is what makes browser-graded R possible at all.  Before it,
// `browser-runner.js` classified a `.R` test script and returned "R test scripts
// require WebR"; WebR was never viable (jupyterlite-webr caps at
// jupyterlite-core<0.7 and we pin 0.8.x), so R could only be graded by the
// native worker.
//
// What this is NOT: a second grading implementation.  RunnerCore (Swift, the
// same code the native worker runs, compiled to wasm) still owns the suite loop,
// dependency gating, and output interpretation.  This worker supplies one
// operation — run a script, report its raw exit code + stdout + stderr — which
// is exactly the seam `ScriptExecutor` was carved out for.
//
// The kernel is the SAME `chickadee-r` env the notebook editor boots for R
// notebooks, so for R "runs in the editor" and "runs in the grader" mean one
// environment and a missing package shows up at authoring time.
//
// Split of responsibilities:
//   /vendor/xeus-bootstrap.js  — the mambajs slice that unpacks a conda env
//   /xeus-kernel-shared.js     — booting a kernel + driving one cell (any kernel)
//   /grading-shared.js         — the emscripten-FS file writer, shared with Pyodide
//   /r-grading-shared.js       — the R wrapper and its reply parsing
//   this file                  — the worker protocol
//
// Protocol (identical in shape to grading-worker.js; every reply carries the
// originating `id`):
//   { id, type: 'init', files: { <relativePath>: <string | number[]> }, seed }
//     → boot the kernel, materialize the file map into a fresh work dir, chdir
//       there, and set CHICKADEE_ASSIGNMENT_SEED when `seed` is non-null
//     → posts back { id, ok: true }  (or { id, ok: false, error })
//   { id, type: 'run', script: <name>, limit: <seconds> }
//     → grade one script, capturing its stdout/stderr and exit code
//     → posts back { id, ok: true, result: { exitCode, stdout, stderr } }
//                or { id, ok: false, error }
//
// As with the Python worker, there is NO timeout here: the main thread races the
// reply against a real timer and calls Worker.terminate() to kill run-away
// student code, which is the only kill path that works against a synchronous
// CPU-bound loop.  R execution inside the kernel is synchronous, so a runaway
// wedges this worker and nothing else.
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

var _kernel = self.ChickadeeXeusKernel;
var _shared = self.ChickadeeGradingShared;
var _r = self.ChickadeeRGradingShared;
var _reply = _kernel.reply;

// Grade one R script and return RAW output { exitCode, stdout, stderr }.  No
// interpretation happens here — RunnerCore maps the exit code to a status and
// reads the last stdout line for the shortResult, byte-for-byte as it does for
// the native `Rscript` subprocess.
async function runRScript(scriptName) {
    var nonce = _r.makeNonce();
    var reply = await _kernel.execute(_r.runScriptR(scriptName, nonce));
    var parsed = _r.parseRunOutput(reply.stdout, nonce);
    if (parsed) {
        // stdout is replayed by the wrapper (so the script's own output is
        // separable from the wrapper's report); stderr is whatever the cell
        // published on the kernel's stderr stream, which is where evaluate's
        // calling handlers put every message()/warning()/error — see the
        // r-grading-shared.js header.
        return { exitCode: parsed.exitCode, stdout: parsed.stdout, stderr: reply.stderr || '' };
    }
    // The wrapper never reported. Surface it as a substrate error (exit 2) with
    // whatever the kernel did say, rather than inventing a pass/fail.
    var detail = reply.failure || (reply.stderr || '').trim()
        || 'the R kernel produced no result for this test';
    return { exitCode: 2, stdout: 'R grading failed: ' + detail, stderr: reply.stderr || '' };
}

self.onmessage = async function (e) {
    var msg = e.data || {};
    var id = msg.id;
    try {
        if (msg.type === 'init') {
            var initT0 = Date.now();
            await _kernel.boot(_r.R_KERNEL);
            // Breadcrumb (no `id`) — the kernel boot is the slow step, so a
            // wedge here is worth telling apart from a wedge in file setup.
            // browser-runner.js forwards these to the submit-phase telemetry.
            _reply({ type: 'phase', phase: 'r_kernel_booted', ms: Date.now() - initT0 });
            _kernel.mountWorkspace(
                '/chickadee_work_' + Date.now(), msg.files, _shared.writeFilesToEmscriptenFS);
            if (msg.seed !== null && msg.seed !== undefined) {
                await _kernel.execute(_r.assignmentSeedR(msg.seed));
            }
            _reply({ type: 'phase', phase: 'r_env_configured', ms: Date.now() - initT0 });
            _reply({ id: id, ok: true });
            return;
        }
        if (msg.type === 'run') {
            var result = await runRScript(msg.script);
            _reply({ id: id, ok: true, result: result });
            return;
        }
        _reply({ id: id, ok: false, error: 'unknown message type: ' + msg.type });
    } catch (err) {
        _reply({ id: id, ok: false, error: (err && err.message) ? String(err.message) : String(err) });
    }
};
