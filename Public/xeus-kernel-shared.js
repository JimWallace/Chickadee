// Public/xeus-kernel-shared.js
//
// Booting a vendored xeus kernel in a plain Web Worker, and driving one cell
// through it.  Substrate mechanics only: nothing here knows what grading is,
// what a test script is, or what an exit code means.  The language-specific
// halves live beside it —
//
//   Public/r-grading-shared.js       — the R wrapper + its reply parsing
//   Public/python-grading-shared.js  — the Python cell + its reply parsing
//
// and the two thin workers (`r-grading-worker.js`, `python-grading-worker.js`)
// wire one to the other.  RunnerCore (Swift/wasm) still owns the suite loop and
// the interpretation of a raw ScriptOutput into a TestOutcome for both, so the
// native and browser graders cannot drift.
//
// Why we boot the kernel ourselves rather than reusing JupyterLite's: the
// vendored @jupyterlite/xeus-extension worker chunks are module-federation
// bundles that `consume` @jupyterlab/services and friends from a share scope
// only the JupyterLab application creates, with no fallback — they die in
// __webpack_require__.f.consumes before any kernel code runs.  The sequence
// below mirrors upstream's EmpackedXeusRemoteKernel (initializeModule →
// waitRunDependencies → empack bootstrap → [bootstrapPython] → xkernel.start)
// against the mambajs slice bundled into /vendor/xeus-bootstrap.js.
//
// Loading: classic script.  Requires /vendor/xeus-bootstrap.js first.
// Exposes exactly one global: ChickadeeXeusKernel.

(function (root) {
    'use strict';

    var bootstrap = root.ChickadeeXeusBootstrap;
    var UNPACK_WASM_URL = '/vendor/xeus-unpack.wasm';

    // Jupyter messages the kernel publishes for the CURRENT execute_request.
    //
    // xeus-lite's emscripten server delivers them by calling the worker's global
    // postMessage — in JupyterLite that reaches the frontend, but a grading
    // worker owns both ends of its own protocol.  So postMessage is wrapped to
    // divert kernel traffic into `sink`, and let everything else through:
    // emscripten's own self-messaging tricks, and the worker's protocol replies.
    var sink = [];
    var passThrough = root.postMessage.bind(root);
    root.postMessage = function (msg) {
        if (msg && typeof msg === 'object' && msg.header && msg.header.msg_type) {
            sink.push(msg);
            return;
        }
        // The kernel's own logger emits {_stream:{name,text}} for boot diagnostics.
        if (msg && typeof msg === 'object' && msg._stream) {
            sink.push({
                header: { msg_type: 'stream' },
                content: { name: msg._stream.name, text: msg._stream.text },
            });
            return;
        }
        try { return passThrough.apply(null, arguments); } catch (_) { /* emscripten self-message */ }
    };

    var _module = null;
    var _server = null;
    var _counter = 0;

    // Boot the kernel named by `spec` (see the KERNEL constants in the two
    // language modules, each mirroring its kernel.json).  Resolves once the
    // kernel is started and ready to take an execute_request.
    async function boot(spec) {
        var envRoot = '/jupyterlite/xeus/' + spec.envName;
        var binaryJS = envRoot + '/bin/' + spec.kernelName + '.js';
        var binaryWASM = envRoot + '/bin/' + spec.kernelName + '.wasm';

        // Defines the global `createXeusModule` factory (emscripten MODULARIZE).
        root.importScripts(binaryJS);

        var mod = await createXeusModule({
            locateFile: function (file) {
                if (Object.prototype.hasOwnProperty.call(spec.sharedLibs, file)) {
                    return envRoot + '/' + spec.kernelName + '/' + file;
                }
                if (file === 'libxeus.so') return envRoot + '/' + file;
                if (file.endsWith('.wasm')) return binaryWASM;
                return file;
            },
        });
        _module = mod;
        // mambajs reads the Module off the global, as it does under JupyterLite.
        root.Module = mod;

        await bootstrap.waitRunDependencies(mod);

        var metaResponse = await fetch(envRoot + '/empack_env_meta.json');
        if (!metaResponse.ok) {
            throw new Error('failed to fetch the ' + spec.kernelName
                + ' kernel environment manifest: HTTP ' + metaResponse.status);
        }
        var empackEnvMeta = await metaResponse.json();
        var pkgRootUrl = envRoot + '/kernel_packages';
        var lock = bootstrap.empackLockToMambajsLock({
            empackEnvMeta: empackEnvMeta, pkgRootUrl: pkgRootUrl,
        });
        // Point untarjs at the vendored unpacking wasm explicitly, rather than
        // letting it fall back to a bundler-injected URL (see setup-vendor.sh).
        var untarjs = await bootstrap.initUntarJS(function () { return UNPACK_WASM_URL; });
        var bootstrapped = await bootstrap.bootstrapEmpackPackedEnvironment({
            empackEnvMeta: empackEnvMeta,
            lock: lock,
            pkgRootUrl: pkgRootUrl,
            Module: mod,
            untarjs: untarjs,
        });

        // xeus-python needs the CPython runtime brought up once the env is on
        // the filesystem; xeus-r has no equivalent step.
        if (spec.needsPythonRuntime) {
            if (!bootstrapped.pythonVersion) {
                throw new Error('the ' + spec.envName + ' environment contains no Python to start');
            }
            await bootstrap.bootstrapPython({
                prefix: empackEnvMeta.prefix,
                pythonVersion: bootstrapped.pythonVersion,
                Module: mod,
            });
        }

        var kernel = new mod.xkernel(spec.argv);
        _server = kernel.get_server();
        if (!_server) throw new Error('the ' + spec.kernelName + ' kernel started but exposed no server');
        kernel.start();
    }

    // Materialize a file map into a fresh work directory and chdir there.
    function mountWorkspace(workDir, files, writeFiles) {
        try { _module.FS.mkdir(workDir); } catch (_) { /* fresh worker; ignore */ }
        writeFiles(_module, workDir, files || {});
        _module.FS.chdir(workDir);
    }

    // Send one execute_request and collect the kernel's replies.  Execution is
    // synchronous inside notify_listener, so by the time it returns the kernel
    // has already published everything; the drain loop only covers a reply
    // posted from a later task.
    async function execute(code) {
        _counter += 1;
        sink = [];
        _server.notify_listener({
            header: {
                msg_id: 'chickadee-' + _counter,
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
        for (var i = 0; i < 400; i++) {
            if (sink.some(function (m) { return m.header.msg_type === 'execute_reply'; })) break;
            await new Promise(function (r) { setTimeout(r, 5); });
        }
        var stdout = '';
        var stderr = '';
        var failure = null;
        sink.forEach(function (m) {
            if (m.header.msg_type === 'stream') {
                if (m.content.name === 'stderr') stderr += m.content.text || '';
                else stdout += m.content.text || '';
            } else if (m.header.msg_type === 'error') {
                failure = [m.content.ename, m.content.evalue].filter(Boolean).join(': ');
            }
        });
        return { stdout: stdout, stderr: stderr, failure: failure };
    }

    root.ChickadeeXeusKernel = {
        boot: boot,
        execute: execute,
        mountWorkspace: mountWorkspace,
        // The worker's protocol replies must bypass the interception above.
        reply: passThrough,
    };
})(typeof self !== 'undefined' ? self : globalThis);
