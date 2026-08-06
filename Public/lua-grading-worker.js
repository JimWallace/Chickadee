// Public/lua-grading-worker.js
//
// The Lua browser-grading substrate: boots the vendored xeus-lua kernel in a Web
// Worker and grades one Lua test script per request.  Sibling of
// Public/r-grading-worker.js and Public/python-grading-worker.js, which do the
// same for xeus-r and xeus-python.
//
// What this is NOT: a third grading implementation.  RunnerCore (Swift, the same
// code the native worker runs, compiled to wasm) still owns the suite loop,
// dependency gating, and output interpretation.  This worker supplies one
// operation — run a script, report its raw exit code + stdout + stderr — which
// is exactly the seam `ScriptExecutor` was carved out for.
//
// Split of responsibilities:
//   /vendor/xeus-bootstrap.js  — the mambajs slice that unpacks a conda env
//   /xeus-kernel-shared.js     — booting a kernel + driving one cell (any kernel)
//   /grading-shared.js         — the emscripten-FS file writer, shared with the others
//   /lua-grading-shared.js     — the Lua wrapper and its reply parsing
//   this file                  — the worker protocol
//
// Protocol (identical in shape to the other two graders; every reply carries the
// originating `id`):
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
// As with the other graders there is NO timeout here: the main thread races the
// reply against a real timer and calls Worker.terminate() to kill run-away
// student code, which is the only kill path that works against a synchronous
// CPU-bound loop.  Lua execution inside the kernel is synchronous, so a runaway
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
importScripts('/lua-grading-shared.js' + _search);

var _kernel = self.ChickadeeXeusKernel;
var _shared = self.ChickadeeGradingShared;
var _lua = self.ChickadeeLuaGradingShared;
var _reply = _kernel.reply;

// `module 'foo' not found:` → foo. Lua words this identically for `require`
// however it is reached, and the following "no file ..." lines are the search
// path rather than another name, so the first capture is the only one.
//
// Lua module names may contain dots (`a.b` maps to `a/b.lua`) and, unlike R
// package names, underscores — the character class follows Lua's own identifier
// rules rather than being copied from the R worker.
var MISSING_LUA_MODULE = /module ['‘"]([A-Za-z_][A-Za-z0-9_.-]*)['’"] not found/;

// Grade one Lua script and return RAW output { exitCode, stdout, stderr }.  No
// interpretation happens here — RunnerCore maps the exit code to a status and
// reads the last stdout line for the shortResult, byte-for-byte as it does for
// the native `lua` subprocess.
//
// The on-demand install retry is wired up even though the vendored env has
// nothing to install: emscripten-forge carries no Lua library packages, so
// `importable-modules.json` for this env has an empty `moduleOwners` and
// `packageForModule` always answers null.  That makes the loop a single pass
// that returns the original failure untouched — which is the behaviour a
// student's `require` typo needs, and is worth proving rather than assuming.
// If Lua packages ever appear on the channel, this is already correct.
async function runLuaScript(scriptName) {
    var parsed = null;
    var reply = await _kernel.runInstallingMissingPackages(
        async function () {
            var nonce = _lua.makeNonce();
            var attemptReply = await _kernel.execute(_lua.runScriptLua(scriptName, nonce));
            parsed = _lua.parseRunOutput(attemptReply.stdout, nonce);
            return attemptReply;
        },
        {
            pattern: MISSING_LUA_MODULE,
            // The wrapper writes an uncaught error to the kernel's stderr
            // stream itself, so a failed require lands there; `failure` covers
            // the case where the wrapper never ran at all.
            textOf: function (r) { return r.stderr || r.failure; },
            onInstall: function (added) {
                _reply({ type: 'phase', phase: 'lua_package_installed', packages: added.join(',') });
            },
        });
    if (parsed) {
        // stdout is everything the kernel published before the wrapper's status
        // line; stderr is whatever the cell published on the kernel's stderr
        // stream, which is where the wrapper puts an uncaught error's message
        // and traceback — see the lua-grading-shared.js header.
        return { exitCode: parsed.exitCode, stdout: parsed.stdout, stderr: reply.stderr || '' };
    }
    // The wrapper never reported. Surface it as a substrate error (exit 2) with
    // whatever the kernel did say, rather than inventing a pass/fail.
    var detail = reply.failure || (reply.stderr || '').trim()
        || 'the Lua kernel produced no result for this test';
    return { exitCode: 2, stdout: 'Lua grading failed: ' + detail, stderr: reply.stderr || '' };
}

self.onmessage = async function (e) {
    var msg = e.data || {};
    var id = msg.id;
    try {
        if (msg.type === 'init') {
            var initT0 = Date.now();
            // No `seeds`: every package in this env is in xeus-lua's own
            // closure, so booting a subset would select all of them. See the
            // note beside LUA_KERNEL.
            await _kernel.boot(_lua.LUA_KERNEL);
            // Breadcrumb (no `id`) — the kernel boot is the slow step, so a
            // wedge here is worth telling apart from a wedge in file setup.
            // browser-runner.js forwards these to the submit-phase telemetry.
            _reply({ type: 'phase', phase: 'lua_kernel_booted', ms: Date.now() - initT0 });
            // The harness has to be installed BEFORE the workspace is mounted:
            // it rewrites package.path with a cwd-relative entry, and doing that
            // after the chdir would be no different, but doing it after a script
            // has already failed to require() would be too late to matter.
            var setup = await _kernel.execute(_lua.SETUP_LUA);
            if (setup.failure) {
                throw new Error('the Lua grading harness failed to install: ' + setup.failure);
            }
            _kernel.mountWorkspace(
                '/chickadee_work_' + Date.now(), msg.files, _shared.writeFilesToEmscriptenFS);
            if (msg.seed !== null && msg.seed !== undefined) {
                await _kernel.execute(_lua.assignmentSeedLua(msg.seed));
            }
            _reply({ type: 'phase', phase: 'lua_env_configured', ms: Date.now() - initT0 });
            _reply({ id: id, ok: true });
            return;
        }
        if (msg.type === 'run') {
            var result = await runLuaScript(msg.script);
            _reply({ id: id, ok: true, result: result });
            return;
        }
        _reply({ id: id, ok: false, error: 'unknown message type: ' + msg.type });
    } catch (err) {
        _reply({ id: id, ok: false, error: (err && err.message) ? String(err.message) : String(err) });
    }
};
