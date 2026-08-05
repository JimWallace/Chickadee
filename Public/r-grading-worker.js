// Public/r-grading-worker.js
//
// xeus-r-in-a-Web-Worker for the browser SUBMISSION grader — the R sibling of
// Public/grading-worker.js, and the substrate that makes browser-graded R
// possible at all.  Before this, `browser-runner.js` classified a `.R` test
// script and returned "R test scripts require WebR"; WebR was never viable
// (jupyterlite-webr caps at jupyterlite-core<0.7 and we pin 0.8.x), so R
// assignments could only be graded by the native worker.
//
// What this is NOT: a second grading implementation.  RunnerCore (Swift, the
// same code the native worker runs, compiled to wasm) still owns the suite
// loop, dependency gating, and output interpretation.  This worker supplies one
// operation — run a script, report its raw exit code + stdout + stderr — which
// is exactly the seam `ScriptExecutor` was carved out for.
//
// Why a bespoke boot rather than JupyterLite's: the vendored
// @jupyterlite/xeus-extension worker chunks are module-federation bundles that
// `consume` @jupyterlab/services and friends from a share scope only the
// JupyterLab application creates, with no fallback — they cannot run in a bare
// worker.  The boot sequence below mirrors upstream's EmpackedXeusRemoteKernel
// (initializeModule → waitRunDependencies → empack bootstrap → xkernel.start),
// using the mambajs slice bundled into /vendor/xeus-bootstrap.js.
//
// Note the kernel is the SAME `chickadee-r` env the notebook editor boots for R
// notebooks.  That is a property Python does not currently have (editor is
// xeus-python, grading is Pyodide): for R, "runs in the editor" and "runs in
// the grader" are the same environment, and a package missing from one is
// missing from both — visible at authoring time rather than at grade time.
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
// As with the Python worker, there is NO timeout here: the main thread races
// the reply against a real timer and calls Worker.terminate() to kill run-away
// student code, which is the only kill path that works against a synchronous
// CPU-bound loop.  R execution inside the kernel is synchronous, so a runaway
// wedges this worker and nothing else.

importScripts('/vendor/xeus-bootstrap.js');
importScripts('/grading-shared.js' + (self.location.search || ''));
importScripts('/r-grading-shared.js' + (self.location.search || ''));

var _bootstrap = self.ChickadeeXeusBootstrap;
var _shared = self.ChickadeeGradingShared;
var _r = self.ChickadeeRGradingShared;

var ENV_ROOT = '/jupyterlite/xeus/' + _r.R_KERNEL.envName;
var UNPACK_WASM_URL = '/vendor/xeus-unpack.wasm';

var _module = null;
var _xkernel = null;
var _xserver = null;
var _workDir = null;

// Jupyter messages the kernel publishes for the CURRENT execute_request.
//
// xeus-lite's emscripten server delivers them by calling the worker's global
// postMessage — in JupyterLite that reaches the frontend, but this worker owns
// both ends of its own protocol, so postMessage is wrapped to divert kernel
// traffic into `_sink` and let everything else (emscripten's own self-messaging
// tricks, and our protocol replies via `_reply`) through untouched.
var _sink = [];
var _reply = self.postMessage.bind(self);
self.postMessage = function (msg) {
    if (msg && typeof msg === 'object' && msg.header && msg.header.msg_type) {
        _sink.push(msg);
        return;
    }
    // The kernel's own logger emits {_stream:{name,text}} for boot diagnostics.
    if (msg && typeof msg === 'object' && msg._stream) {
        _sink.push({
            header: { msg_type: 'stream' },
            content: { name: msg._stream.name, text: msg._stream.text },
        });
        return;
    }
    try { return _reply.apply(null, arguments); } catch (_) { /* emscripten self-message */ }
};

async function bootKernel() {
    var spec = _r.R_KERNEL;
    var binaryJS = ENV_ROOT + '/bin/' + spec.kernelName + '.js';
    var binaryWASM = ENV_ROOT + '/bin/' + spec.kernelName + '.wasm';

    // Defines the global `createXeusModule` factory (emscripten MODULARIZE).
    importScripts(binaryJS);

    var mod = await createXeusModule({
        locateFile: function (file) {
            if (Object.prototype.hasOwnProperty.call(spec.sharedLibs, file)) {
                return ENV_ROOT + '/' + spec.kernelName + '/' + file;
            }
            if (file === 'libxeus.so') return ENV_ROOT + '/' + file;
            if (file.endsWith('.wasm')) return binaryWASM;
            return file;
        },
    });
    _module = mod;
    // mambajs reads the Module off the global, as it does under JupyterLite.
    globalThis.Module = mod;

    await _bootstrap.waitRunDependencies(mod);

    var metaResponse = await fetch(ENV_ROOT + '/empack_env_meta.json');
    if (!metaResponse.ok) {
        throw new Error('failed to fetch the R kernel environment manifest: HTTP ' + metaResponse.status);
    }
    var empackEnvMeta = await metaResponse.json();
    var pkgRootUrl = ENV_ROOT + '/kernel_packages';
    var lock = _bootstrap.empackLockToMambajsLock({
        empackEnvMeta: empackEnvMeta, pkgRootUrl: pkgRootUrl,
    });
    // Point untarjs at the vendored unpacking wasm explicitly, rather than
    // letting it fall back to a bundler-injected URL (see setup-vendor.sh).
    var untarjs = await _bootstrap.initUntarJS(function () { return UNPACK_WASM_URL; });
    await _bootstrap.bootstrapEmpackPackedEnvironment({
        empackEnvMeta: empackEnvMeta,
        lock: lock,
        pkgRootUrl: pkgRootUrl,
        Module: mod,
        untarjs: untarjs,
    });

    _xkernel = new mod.xkernel(spec.argv);
    _xserver = _xkernel.get_server();
    if (!_xserver) throw new Error('the R kernel started but exposed no server');
    _xkernel.start();
}

var _msgCounter = 0;

// Send one execute_request and collect the kernel's replies.  R runs
// synchronously inside notify_listener, so by the time it returns the kernel
// has already published everything; the drain loop only covers the case where a
// reply is posted from a later task.
async function executeR(code) {
    _msgCounter += 1;
    _sink = [];
    _xserver.notify_listener({
        header: {
            msg_id: 'chickadee-' + _msgCounter,
            session: 'chickadee-grading',
            username: 'chickadee',
            date: new Date().toISOString(),
            msg_type: 'execute_request',
            version: '5.3',
        },
        parent_header: {},
        metadata: {},
        content: {
            code: code,
            silent: false,
            store_history: false,
            user_expressions: {},
            allow_stdin: false,
            stop_on_error: false,
        },
        channel: 'shell',
        buffers: [],
    });
    for (var i = 0; i < 200; i++) {
        if (_sink.some(function (m) { return m.header.msg_type === 'execute_reply'; })) break;
        await new Promise(function (r) { setTimeout(r, 5); });
    }
    var stdout = '';
    var stderr = '';
    var failure = null;
    _sink.forEach(function (m) {
        if (m.header.msg_type === 'stream') {
            if (m.content.name === 'stderr') stderr += m.content.text || '';
            else stdout += m.content.text || '';
        } else if (m.header.msg_type === 'error') {
            failure = [m.content.ename, m.content.evalue].filter(Boolean).join(': ');
        }
    });
    return { stdout: stdout, stderr: stderr, failure: failure };
}

// Grade one R script and return RAW output { exitCode, stdout, stderr }.  No
// interpretation happens here — RunnerCore maps the exit code to a status and
// reads the last stdout line for the shortResult, byte-for-byte as it does for
// the native `Rscript` subprocess.
async function runRScript(scriptName) {
    var nonce = _r.makeNonce();
    var reply = await executeR(_r.runScriptR(scriptName, nonce));
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
            await bootKernel();
            // Breadcrumb (no `id`) — the R kernel boot is the slow step, so a
            // wedge here is worth telling apart from a wedge in file setup.
            // browser-runner.js forwards these to the submit-phase telemetry.
            _reply({ type: 'phase', phase: 'r_kernel_booted', ms: Date.now() - initT0 });
            _workDir = '/chickadee_work_' + Date.now();
            try { _module.FS.mkdir(_workDir); } catch (err) { /* fresh worker; ignore */ }
            _shared.writeFilesToEmscriptenFS(_module, _workDir, msg.files || {});
            _module.FS.chdir(_workDir);
            if (msg.seed !== null && msg.seed !== undefined) {
                await executeR(_r.assignmentSeedR(msg.seed));
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
