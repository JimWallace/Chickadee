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

    // Kept from boot so packages can be added to the LIVE kernel afterwards —
    // see addPackages below.
    var _meta = null;
    var _untarjs = null;
    var _pkgRootUrl = null;
    var _installed = null;
    var _moduleOwners = null;

    // The package name out of a conda dependency spec ("python >=3.9" → "python").
    function dependencyName(spec) {
        return String(spec).trim().split(/[\s<>=!]/)[0];
    }

    // Transitive closure of `seeds` over empack_env_meta.json's own `depends`
    // arrays. The manifest is self-describing, so this needs no solver and no
    // network: every package the environment can install is already listed with
    // its dependencies, and we are only ever choosing a subset of it.
    function closure(meta, seeds) {
        var byName = {};
        meta.packages.forEach(function (p) { byName[p.name] = p; });
        var seen = Object.create(null);
        var stack = seeds.slice();
        while (stack.length) {
            var name = stack.pop();
            if (seen[name] || !byName[name]) continue;
            seen[name] = true;
            (byName[name].depends || []).forEach(function (d) {
                stack.push(dependencyName(d));
            });
        }
        return Object.keys(seen);
    }

    // `meta` restricted to `names`, preserving every other field. mambajs reads
    // the package list and nothing else about the shape, so a filtered copy is
    // a valid manifest.
    function subsetMeta(meta, names) {
        var keep = Object.create(null);
        names.forEach(function (n) { keep[n] = true; });
        var copy = {};
        Object.keys(meta).forEach(function (k) { copy[k] = meta[k]; });
        copy.packages = meta.packages.filter(function (p) { return keep[p.name]; });
        return copy;
    }

    // Unpack a manifest (whole or subset) into the emscripten FS.
    async function installMeta(meta) {
        var lock = bootstrap.empackLockToMambajsLock({
            empackEnvMeta: meta, pkgRootUrl: _pkgRootUrl,
        });
        return await bootstrap.bootstrapEmpackPackedEnvironment({
            empackEnvMeta: meta,
            lock: lock,
            pkgRootUrl: _pkgRootUrl,
            Module: _module,
            untarjs: _untarjs,
        });
    }

    // Boot the kernel named by `spec` (see the KERNEL constants in the two
    // language modules, each mirroring its kernel.json).  Resolves once the
    // kernel is started and ready to take an execute_request.
    //
    // `options.seeds`, when given, boots only the closure of those package names
    // instead of the whole environment — the rest can be added later with
    // addPackages. Omitting it installs everything, which is the original
    // behaviour byte for byte.
    //
    // Why bother: installing a package is untar + FS write + dlopen, and that
    // cost is paid even when every byte is already in the browser cache.
    // Measured on the Python env (Chromium, 3 runs, local disk so download is
    // ~free): full 48-package env 8604 ms, bare kernel 4822 ms, kernel+numpy
    // 4839 ms. 84% of that env is optional data-science packages.
    async function boot(spec, options) {
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
        _meta = await metaResponse.json();
        _pkgRootUrl = envRoot + '/kernel_packages';
        // Point untarjs at the vendored unpacking wasm explicitly, rather than
        // letting it fall back to a bundler-injected URL (see setup-vendor.sh).
        _untarjs = await bootstrap.initUntarJS(function () { return UNPACK_WASM_URL; });

        // module → owning conda package, generated from the same tarballs by
        // scripts/derive-kernel-modules.py. Only needed to turn a
        // ModuleNotFoundError back into something installable, so a missing or
        // malformed index degrades to "no on-demand loading" rather than
        // failing the boot.
        try {
            var indexResponse = await fetch(envRoot + '/importable-modules.json');
            if (indexResponse.ok) {
                var index = await indexResponse.json();
                _moduleOwners = (index && index.moduleOwners) || null;
            }
        } catch (_) { _moduleOwners = null; }

        var seeds = options && options.seeds;
        _installed = seeds
            ? closure(_meta, seeds)
            : _meta.packages.map(function (p) { return p.name; });
        var empackEnvMeta = seeds ? subsetMeta(_meta, _installed) : _meta;
        var bootstrapped = await installMeta(empackEnvMeta);

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

    // Install more of the environment into the ALREADY-RUNNING kernel.
    //
    // The empack bootstrap is additive against a live Module — it unpacks into
    // the same emscripten FS — and `loadSharedLibs` dlopen()s any native
    // extensions the new packages carry, which is the same step boot runs.
    // Verified against a real kernel, not reasoned about: Tools/browser-grading-smoke
    // boots a strict subset, asserts the package is genuinely missing, adds it,
    // and asserts it then imports and computes.
    //
    // Returns the package names actually installed (empty if all were present),
    // so a caller can tell "added it" from "it was never the problem" without
    // guessing.
    async function addPackages(seeds) {
        if (!_meta) throw new Error('addPackages called before boot');
        var already = Object.create(null);
        _installed.forEach(function (n) { already[n] = true; });
        var wanted = closure(_meta, seeds).filter(function (n) { return !already[n]; });
        if (!wanted.length) return [];

        // Unpack from the environment prefix, not the student workspace. By the
        // time a script triggers an install the kernel has chdir'd into
        // /chickadee_work_*, and the unpacker resolves at least some paths
        // relative to cwd — installing from there fails inside the bundle with
        // a bare Error. Restore it afterwards so the running script still sees
        // the working directory the grading contract promises.
        var cwd = null;
        try { cwd = _module.FS.cwd(); _module.FS.chdir('/'); } catch (_) { cwd = null; }
        var result;
        try {
            result = await installMeta(subsetMeta(_meta, wanted));
        } finally {
            if (cwd) { try { _module.FS.chdir(cwd); } catch (_) { /* workspace gone */ } }
        }
        wanted.forEach(function (n) { _installed.push(n); });

        if (result && result.sharedLibs) {
            await bootstrap.loadSharedLibs({
                sharedLibs: result.sharedLibs,
                prefix: _meta.prefix,
                Module: _module,
            });
        }
        return wanted;
    }

    // True if `name` is a package this environment could still install.
    function canInstall(name) {
        if (!_meta) return false;
        return _meta.packages.some(function (p) { return p.name === name; });
    }

    // The conda package that ships importable `moduleName`, or null when the
    // environment has no such module — in which case nothing can be installed
    // and the caller should let the original error stand.
    function packageForModule(moduleName) {
        if (!_moduleOwners) return null;
        var owner = _moduleOwners[moduleName];
        return (owner && canInstall(owner)) ? owner : null;
    }

    // The backstop on re-runs, not the expected count. Every pass must install
    // at least one package that was not installed before, so the installable set
    // strictly shrinks and the loop terminates on its own; this only guards
    // against a pathological environment. It has to comfortably exceed the
    // number of packages one script can name — the R smoke's fixture attaches
    // all seven tidyverse packages in a loop, which is seven passes on a bare
    // kernel — so it is set well above any real script rather than tuned.
    var MAX_ON_DEMAND_PASSES = 16;

    // Run `attempt` until it stops failing on a package the environment could
    // supply, installing what it asks for in between.
    //
    // Both languages need exactly this, with three things differing: the regex
    // that names the missing thing, where in the reply to look for it, and
    // whether anything must run after an install. Sharing the loop is the point
    // — a retry that terminates for Python and spins for R would be a very
    // expensive way to find out they had drifted.
    //
    // `options`:
    //   pattern      — RegExp whose first capture group is the missing name
    //   textOf       — (result) => string to search
    //   afterInstall — optional source to execute once packages land
    //   onInstall    — optional (names) => void, for telemetry
    //
    // Returns whatever `attempt` last returned. Any step that cannot make
    // progress — no match, no owning package, nothing new installed — returns
    // that result untouched, so the caller sees the original failure exactly as
    // it would without this.
    async function runInstallingMissingPackages(attempt, options) {
        for (var pass = 0; ; pass++) {
            var result = await attempt();
            if (pass >= MAX_ON_DEMAND_PASSES) return result;

            var match = options.pattern.exec(options.textOf(result) || '');
            if (!match) return result;

            var pkg = packageForModule(match[1]);
            if (!pkg) return result;

            var added = await addPackages([pkg]);
            if (!added.length) return result;

            if (options.afterInstall) await execute(options.afterInstall);
            if (options.onInstall) options.onInstall(added);
        }
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
    // How long `execute` keeps polling for the kernel's execute_reply before
    // giving up. This is a DEAD-KERNEL BACKSTOP, not an execution timeout: a
    // xeus-lite cell runs inside `notify_listener`, so a long-running cell
    // blocks this worker's event loop outright and the reply is already in the
    // sink by the time the poll below gets a turn. The cap only matters when a
    // reply is never coming — a kernel that crashed or was killed mid-cell —
    // where it stops `execute` hanging forever.
    //
    // Wall-clock limits on student or instructor code are enforced from the MAIN
    // thread, which races the worker's reply against a timer and calls
    // `Worker.terminate()`. That is the only kill path that works against a
    // synchronous CPU-bound loop, and it is why this number does not have to be
    // generous.
    //
    // Measured, so it is not just an argument: the R leg of
    // Tools/browser-grading-smoke grades a script taking 3,139 ms and passes
    // under this 2,000 ms cap. If the cap were an execution timeout that script
    // would report a bogus result instead.
    var DEFAULT_MAX_WAIT_MS = 2000;

    async function execute(code, options) {
        var maxWaitMs = (options && options.maxWaitMs) || DEFAULT_MAX_WAIT_MS;
        var polls = Math.max(1, Math.ceil(maxWaitMs / 5));
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
        for (var i = 0; i < polls; i++) {
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
        addPackages: addPackages,
        canInstall: canInstall,
        packageForModule: packageForModule,
        runInstallingMissingPackages: runInstallingMissingPackages,
        // Exported for tests: the subset a given set of seeds implies is the
        // whole design, and asserting it against the real vendored manifest
        // beats a copy of this walk that can drift from it.
        packageClosure: closure,
        execute: execute,
        mountWorkspace: mountWorkspace,
        // The worker's protocol replies must bypass the interception above.
        reply: passThrough,
    };
})(typeof self !== 'undefined' ? self : globalThis);
