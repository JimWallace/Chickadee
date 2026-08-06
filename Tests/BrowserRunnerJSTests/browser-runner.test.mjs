import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const runnerSource = await fs.readFile(
  path.resolve('Public/browser-runner.js'),
  'utf8',
);
const sharedSource = await fs.readFile(
  path.resolve('Public/grading-shared.js'),
  'utf8',
);
const rSharedSource = await fs.readFile(
  path.resolve('Public/r-grading-shared.js'),
  'utf8',
);

// Shared producer/parser contract for the dependency-skip wording; the worker
// side is pinned by Tests/CoreTests/DependencySkipMessageTests.swift.
const skipFixture = JSON.parse(
  await fs.readFile(path.resolve('Tests/Fixtures/dependency-skip-message.json'), 'utf8'),
);

// Mirrors RunnerCore.classifyScriptInterpreter (the real logic is wasm/Swift,
// covered by ScriptClassificationTests) — returns the interpreter raw value so
// the browser dispatch wiring can be tested without loading the wasm.
function defaultClassifyStub(name, source) {
  const base = String(name).slice(String(name).lastIndexOf('/') + 1);
  const dot = base.lastIndexOf('.');
  const ext = dot > 0 ? base.slice(dot + 1).toLowerCase() : '';
  const byExt = { py: 'python', sh: 'sh', bash: 'bash', zsh: 'zsh', rb: 'ruby', pl: 'perl', js: 'node', php: 'php', r: 'rscript', lua: 'lua' };
  if (byExt[ext]) return byExt[ext];
  const first = String(source || '').replace(/^[\uFEFF\s]+/, '').split('\n', 1)[0] || '';
  if (first.startsWith('#!')) {
    const lo = first.toLowerCase();
    if (lo.includes('python')) return 'python';
    if (lo.includes('node') || lo.includes('javascript')) return 'node';
    if (lo.includes('ruby')) return 'ruby';
    if (lo.includes('perl')) return 'perl';
    if (lo.includes('lua')) return 'lua';
    if (lo.includes('bash')) return 'bash';
    if (lo.includes('zsh')) return 'zsh';
    if (lo.includes('sh')) return 'sh';
  }
  const lines = String(source || '').split('\n').map(l => l.trim()).filter(l => l && !l.startsWith('#')).slice(0, 5);
  if (lines.some(l => l.startsWith('import ') || l.startsWith('from ') || l.startsWith('def ') || l.startsWith('class ') || l.startsWith('if __name__ =='))) {
    return 'python';
  }
  return 'unknown';
}

// Same-realm test double for the shared RunnerCore `executeSuites` +
// `interpretScriptOutput`. The REAL wasm interpretation/loop are pinned against
// the shared fixture by output-contract.test.mjs (which drives the actual wasm)
// and by the Swift SuiteExecutionTests / OutputContractTests. Here we only need
// a faithful-enough stand-in so the browser-runner GLUE (suite building,
// run/exists wiring, dependency gating, collection posting) can be exercised in
// this vm realm — loading the real wasm here would hit a cross-realm Promise
// hazard (the run callback's Promise lives in the vm realm, not the wasm's).
function stemOf(name) {
  const slash = name.lastIndexOf('/');
  const dot = name.lastIndexOf('.');
  return dot > slash + 1 ? name.slice(0, dot) : name;
}
function defaultShort(status) {
  return status === 'pass' ? 'passed' : status === 'fail' ? 'failed' : status === 'timeout' ? 'timed out' : 'error';
}
function longResultOf(raw, footerObj) {
  // A footer `traceback` is the most useful detail — surface it verbatim.
  if (footerObj && typeof footerObj.traceback === 'string' && footerObj.traceback.trim()) {
    return footerObj.traceback.trim();
  }
  let stdout = String(raw.stdout || '');
  if (footerObj) {
    const arr = stdout.split('\n');
    for (let i = arr.length - 1; i >= 0; i--) { if (arr[i].trim()) { arr.splice(i, 1); break; } }
    stdout = arr.join('\n');
  }
  stdout = stdout.trim();
  const stderr = String(raw.stderr || '').trim();
  const sections = [];
  if (stdout) sections.push('stdout:\n' + stdout);
  if (stderr) sections.push('stderr:\n' + stderr);
  return sections.length ? sections.join('\n\n') : null;
}
function interpretRaw(raw) {
  if (raw.timedOut) return { status: 'timeout', shortResult: 'timed out', longResult: longResultOf(raw, null) };
  const status = raw.exitCode === 0 ? 'pass' : (raw.exitCode === 1 || raw.exitCode === 3) ? 'fail' : 'error';
  const lines = String(raw.stdout || '').split('\n').map(l => l.trim()).filter(Boolean);
  const last = lines[lines.length - 1] || '';
  let footerObj = null;
  if (last) {
    try {
      const obj = JSON.parse(last);
      if (obj && typeof obj === 'object' && !Array.isArray(obj)) footerObj = obj;
    } catch (_) { /* not a JSON footer */ }
  }
  let shortResult;
  if (footerObj) {
    shortResult = typeof footerObj.shortResult === 'string' ? footerObj.shortResult : defaultShort(status);
    // Strip a redundant "<test>: " label prefix when the footer names the test.
    if (typeof footerObj.test === 'string' && footerObj.test) {
      const prefix = footerObj.test + ': ';
      if (shortResult.startsWith(prefix)) shortResult = shortResult.slice(prefix.length);
    }
  } else {
    shortResult = last || defaultShort(status);
  }
  return { status, shortResult, longResult: longResultOf(raw, footerObj) };
}
function makeStubOutcome(suite, interp, executionTimeMs, attempt) {
  const displayName = (typeof suite.displayName === 'string' && suite.displayName.trim()) ? suite.displayName : null;
  return {
    testName: displayName || stemOf(suite.script),
    testClass: null,
    tier: suite.tier,
    status: interp.status,
    shortResult: interp.shortResult,
    longResult: interp.longResult ?? null,
    points: typeof suite.points === 'number' ? suite.points : 1,
    executionTimeMs,
    memoryUsageBytes: null,
    attemptNumber: attempt,
    isFirstPassSuccess: attempt === 1 && interp.status === 'pass',
  };
}
function executeSuitesStub(suites, timeLimit, attempt, scriptExists, run) {
  return (async () => {
    const outcomes = [];
    const passed = new Set();
    for (const suite of suites) {
      const deps = suite.dependsOn || [];
      const blockedBy = deps.find(dep => !passed.has(dep));
      if (deps.length && blockedBy !== undefined) {
        outcomes.push(makeStubOutcome(suite,
          { status: 'fail', shortResult: `Skipped: prerequisite '${blockedBy}' did not pass`, longResult: null },
          0, attempt));
        continue;
      }
      if (!scriptExists(suite.script)) continue;
      const raw = await run(suite.script, timeLimit);
      const interp = interpretRaw(raw);
      outcomes.push(makeStubOutcome(suite, interp, raw.executionTimeMs, attempt));
      if (interp.status === 'pass') passed.add(suite.script);
    }
    return outcomes;
  })();
}

function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

class FakeFS {
  constructor() {
    this.entries = new Map([['/', { type: 'dir' }]]);
    this.writes = [];
  }

  mkdir(targetPath) {
    if (this.entries.has(targetPath)) {
      const existing = this.entries.get(targetPath);
      if (existing.type !== 'dir') throw new Error(`Path exists as file: ${targetPath}`);
      return;
    }
    const parent = parentDir(targetPath);
    if (!this.entries.has(parent) || this.entries.get(parent).type !== 'dir') {
      throw new Error(`Missing parent directory: ${parent}`);
    }
    this.entries.set(targetPath, { type: 'dir' });
  }

  writeFile(targetPath, value) {
    const parent = parentDir(targetPath);
    if (!this.entries.has(parent) || this.entries.get(parent).type !== 'dir') {
      throw new Error(`Missing parent directory: ${parent}`);
    }
    this.writes.push({ targetPath, value });
    this.entries.set(targetPath, { type: 'file', value });
  }

  readFile(targetPath, options = {}) {
    const entry = this.entries.get(targetPath);
    if (!entry || entry.type !== 'file') throw new Error(`No such file: ${targetPath}`);
    if (options.encoding === 'utf8') {
      return typeof entry.value === 'string'
        ? entry.value
        : new TextDecoder().decode(toUint8Array(entry.value));
    }
    return toUint8Array(entry.value);
  }

  stat(targetPath) {
    const entry = this.entries.get(targetPath);
    if (!entry) throw new Error(`No such path: ${targetPath}`);
    return { mode: entry.type === 'dir' ? 0o040000 : 0o100000 };
  }

  isDir(mode) {
    return (mode & 0o040000) === 0o040000;
  }

  readdir(targetPath) {
    const entry = this.entries.get(targetPath);
    if (!entry || entry.type !== 'dir') throw new Error(`No such directory: ${targetPath}`);
    const children = new Set(['.', '..']);
    const prefix = targetPath === '/' ? '/' : `${targetPath}/`;
    for (const key of this.entries.keys()) {
      if (!key.startsWith(prefix) || key === targetPath) continue;
      const remainder = key.slice(prefix.length);
      if (!remainder || remainder.includes('/')) continue;
      children.add(remainder);
    }
    return [...children];
  }

  unlink(targetPath) {
    const entry = this.entries.get(targetPath);
    if (!entry || entry.type !== 'file') throw new Error(`No such file: ${targetPath}`);
    this.entries.delete(targetPath);
  }

  rmdir(targetPath) {
    for (const key of this.entries.keys()) {
      if (key !== targetPath && key.startsWith(`${targetPath}/`)) {
        throw new Error(`Directory not empty: ${targetPath}`);
      }
    }
    this.entries.delete(targetPath);
  }

  exists(targetPath) {
    return this.entries.has(targetPath);
  }
}

function parentDir(targetPath) {
  if (targetPath === '/') return '/';
  const idx = targetPath.lastIndexOf('/');
  if (idx <= 0) return '/';
  return targetPath.slice(0, idx);
}

function toUint8Array(value) {
  if (value instanceof Uint8Array) return value;
  if (typeof value === 'string') return new TextEncoder().encode(value);
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  return new Uint8Array(value);
}

function makeZipEntry(value) {
  return {
    dir: false,
    async async(kind) {
      assert.equal(kind, 'uint8array');
      return toUint8Array(value);
    },
  };
}

function makeTuple(value) {
  return {
    toJs() {
      return value;
    },
    destroy() {},
  };
}

function createPyodideHarness(options = {}) {
  const fs = new FakeFS();
  const state = {
    cwd: '/',
    stdout: '',
    stderr: '',
    exitCode: null,
    loadPackageCalls: [],
    configuredScripts: [],
    assignmentSeedEnv: null,
  };

  const py = {
    FS: fs,
    state,
    async loadPackagesFromImports(src) {
      state.loadPackageCalls.push(src);
      if (options.packageError) throw options.packageError;
    },
    async runPythonAsync(code) {
      if (code.includes("os.environ['CHICKADEE_ASSIGNMENT_SEED']")) {
        const m = code.match(/CHICKADEE_ASSIGNMENT_SEED'\]\s*=\s*"([^"]*)"/);
        if (m) state.assignmentSeedEnv = m[1];
        return null;
      }

      if (code.includes("os.chdir('")) {
        const match = code.match(/os\.chdir\('([^']+)'\)/);
        if (match) state.cwd = match[1];
        return null;
      }

      if (code.includes('_br_stdout = io.StringIO()')) {
        state.stdout = '';
        state.stderr = '';
        state.exitCode = null;
        return null;
      }

      if (code.includes("compile(open('")) {
        const match = code.match(/compile\(open\('([^']+)'/);
        const scriptName = match ? match[1] : null;
        if (!scriptName) throw new Error(`Could not determine script name from code: ${code}`);
        state.configuredScripts.push(scriptName);
        const behavior = resolveScriptBehavior(scriptName, fs, state.cwd, options.scriptBehaviors);
        if (behavior.pending) return new Promise(() => {});
        if (behavior.reject) return Promise.reject(behavior.reject);
        state.stdout = behavior.stdout ?? '';
        state.stderr = behavior.stderr ?? '';
        state.exitCode = behavior.exitCode ?? null;
        return null;
      }

      if (code.includes('str(_br_stdout.getvalue())')) {
        return makeTuple([state.stdout, state.stderr, state.exitCode]);
      }

      if (code.includes('sys.stdout = sys.__stdout__')) {
        return null;
      }

      return null;
    },
  };

  fs.mkdir('/tmp');
  return py;
}

function resolveScriptBehavior(scriptName, fs, cwd, configured = {}) {
  if (configured[scriptName]) return configured[scriptName];

  const raw = fs.readFile(`${cwd}/${scriptName}`, { encoding: 'utf8' });
  const lines = raw.trim().split('\n');
  const lastLine = lines[lines.length - 1] || '';
  if (lastLine.includes('JSON_RESULT_PASS')) {
    return {
      stdout: `${JSON.stringify({ shortResult: `${scriptName}: passed`, status: 'pass' })}\n`,
      stderr: '',
      exitCode: 0,
    };
  }
  if (lastLine.includes('JSON_RESULT_FAIL')) {
    return {
      stdout: `${JSON.stringify({ shortResult: `${scriptName}: failed`, status: 'fail' })}\n`,
      stderr: 'assertion failed\n',
      exitCode: 1,
    };
  }
  return {
    stdout: '',
    stderr: '',
    exitCode: 0,
  };
}

// A fake grading worker (Public/grading-worker.js stand-in) for the
// GradingWorkerExecutor path.  It speaks the same postMessage protocol:
//   { id, type:'init', files, seed } -> { id, ok:true }
//   { id, type:'run', script, limit } -> { id, ok:true, result:{exitCode,stdout,stderr} }
// A `{ pending: true }` behavior NEVER replies — simulating a real worker stuck
// in a synchronous CPU-bound loop (the exact case that hung the old
// main-thread Promise.race).  The real worker can't be loaded under `node
// --test` (it needs real Pyodide), so this double exercises the kill/respawn
// glue the executor wraps around it.  The factory tracks every worker it spawns
// so a test can assert a fresh worker was created after a terminate().
function makeFakeGradingWorkerFactory(options) {
  const created = [];

  class FakeGradingWorker {
    constructor() {
      this.onmessage = null;
      this.onerror = null;
      this.terminated = false;
      this.postedTypes = [];
      this.files = {};
      // Records every `run` message's { script, limit } so a test can assert
      // the per-script time limit the executor handed down.
      this.runCalls = [];
      created.push(this);
    }

    _reply(message) {
      // Replies are always async (matches a real Worker's message channel).
      Promise.resolve().then(() => {
        if (this.terminated) return;
        if (typeof this.onmessage === 'function') this.onmessage({ data: message });
      });
    }

    _behaviorFor(scriptName) {
      const configured = options.scriptBehaviors || {};
      if (configured[scriptName]) return configured[scriptName];
      const raw = this.files[scriptName];
      const text = typeof raw === 'string'
        ? raw
        : new TextDecoder().decode(raw instanceof Uint8Array ? raw : new Uint8Array(raw || []));
      const lines = String(text).trim().split('\n');
      const lastLine = lines[lines.length - 1] || '';
      if (lastLine.includes('JSON_RESULT_PASS')) {
        return { stdout: `${JSON.stringify({ shortResult: `${scriptName}: passed`, status: 'pass' })}\n`, stderr: '', exitCode: 0 };
      }
      if (lastLine.includes('JSON_RESULT_FAIL')) {
        return { stdout: `${JSON.stringify({ shortResult: `${scriptName}: failed`, status: 'fail' })}\n`, stderr: 'assertion failed\n', exitCode: 1 };
      }
      return { stdout: '', stderr: '', exitCode: 0 };
    }

    postMessage(msg) {
      this.postedTypes.push(msg.type);
      if (this.terminated) return;
      if (msg.type === 'init') {
        this.files = msg.files || {};
        this.seed = msg.seed ?? null;
        // `initPending` simulates a worker whose loadPyodide()/env-config never
        // completes (the intermittent Pyodide-314 init hang) — it NEVER replies,
        // so the executor's bounded-init timeout must terminate + retry it.
        if (options.initPending) return;
        this._reply({ id: msg.id, ok: true });
        return;
      }
      if (msg.type === 'run') {
        this.runCalls.push({ script: msg.script, limit: msg.limit });
        const behavior = this._behaviorFor(msg.script);
        if (behavior.pending) return;  // never reply — simulates a real hang
        this._reply({
          id: msg.id,
          ok: true,
          result: {
            exitCode: behavior.exitCode ?? 0,
            stdout: behavior.stdout ?? '',
            stderr: behavior.stderr ?? '',
          },
        });
        return;
      }
      this._reply({ id: msg.id, ok: false, error: `unknown message type: ${msg.type}` });
    }

    terminate() {
      this.terminated = true;
    }
  }

  // browser-runner passes the worker script path so one factory can serve both
  // substrates (/grading-worker.js and /r-grading-worker.js); record it so a
  // routing test can assert which runtime a script was sent to.
  const factory = (scriptPath) => {
    const worker = new FakeGradingWorker();
    worker.scriptPath = scriptPath ?? null;
    return worker;
  };
  factory.created = created;
  return factory;
}

async function loadRunnerHarness(options = {}) {
  const statusEl = { hidden: true, textContent: '', className: '' };
  const scriptLoads = [];
  const postBodies = [];
  const fetchCalls = [];
  const breadcrumbs = [];
  const testHooks = {};
  const py = options.pyodide ?? createPyodideHarness(options);

  const zipFiles = options.zipFiles ?? {};
  const zipEntries = {};
  for (const [name, value] of Object.entries(zipFiles)) {
    zipEntries[name] = makeZipEntry(value);
  }

  const document = {
    currentScript: {
      dataset: {
        gradingMode: options.gradingMode ?? 'browser',
      },
    },
    head: {
      appendChild(node) {
        scriptLoads.push(node.src);
        if (typeof node.onload === 'function') node.onload();
      },
    },
    createElement() {
      return {
        src: '',
        onload: null,
        onerror: null,
      };
    },
    getElementById(id) {
      return id === 'browser-runner-status' ? statusEl : null;
    },
  };

  const fetchImpl = async (url, init = {}) => {
    fetchCalls.push({ url, init });
    // Submit-phase breadcrumbs (fire-and-forget telemetry) — capture and ack.
    if (url.includes('/client-diagnostics')) {
      try { breadcrumbs.push(JSON.parse(init.body)); } catch (_) { breadcrumbs.push({ raw: init.body }); }
      return { ok: true, async json() { return {}; } };
    }
    if (init.method === 'POST') {
      const body = init.body;
      const collection = body.get('collection');
      const testSetupID = body.get('testSetupID');
      const notebook = body.get('notebook');
      postBodies.push({
        url,
        csrf: init.headers?.['x-csrf-token'] ?? null,
        collection: JSON.parse(collection),
        testSetupID,
        notebookText: await notebook.text(),
      });
      return {
        ok: true,
        async json() {
          return { submissionID: 'sub_test_123' };
        },
      };
    }

    if (url.endsWith('/seed')) {
      if (options.seedFetchResponse) return options.seedFetchResponse;
      return {
        ok: true,
        async text() {
          return JSON.stringify({
            seed: options.assignmentSeed ?? null,
            personalizedInputs: options.personalizedInputs ?? null,
            // The server resolves the assignment's language here so the browser
            // knows which per-student inputs FILE to write (#1271).
            language: options.assignmentLanguage ?? null,
            // ...and which runtime executes Python test scripts.
            pythonSubstrate: options.assignmentPythonSubstrate ?? 'pyodide',
          });
        },
      };
    }

    if (url.includes('/download')) {
      if (options.downloadError) throw options.downloadError;
      return {
        ok: true,
        async arrayBuffer() {
          return new Uint8Array([1, 2, 3]).buffer;
        },
      };
    }

    if (url.includes('/manifest')) {
      if (options.manifestFetchResponse) return options.manifestFetchResponse;
      return {
        ok: true,
        async text() {
          return JSON.stringify(options.manifest ?? {
            gradingMode: 'browser',
            timeLimitSeconds: 10,
            testSuites: [],
          });
        },
      };
    }

    throw new Error(`Unexpected fetch URL: ${url}`);
  };

  const context = {
    console,
    setTimeout,
    clearTimeout,
    TextDecoder,
    TextEncoder,
    Blob,
    FormData,
    Uint8Array,
    ArrayBuffer,
    Date,
    JSON,
    Error,
    fetch: fetchImpl,
    ChickadeeUI: { getCsrfToken: () => options.csrfToken ?? 'csrf-test-token' },
    document,
    // Test seam: preset the RunnerCore extractors so the runner never loads
    // the real wasm bundle. The actual extraction logic is covered by the
    // Swift RunnerCore tests; here stubs return deterministic output.
    runnerExtractPython: options.runnerExtractor ?? ((cells, filename) => ({
      executableModule: `# Generated from ${filename}\n# (stub executable module)\n`,
      introspectableSource: `# Generated from ${filename}\n# (stub introspectable source)\n`,
      codeCellCount: (cells || []).filter(c => c.cell_type === 'code').length,
    })),
    // Faithful double of RunnerCore.extractR (real logic covered by the Swift
    // RNotebookExtractionTests): header + a position-numbered marker per kept
    // cell, trailing whitespace trimmed.
    runnerExtractR: options.runnerExtractR ?? ((cells, filename) => {
      let source = `# Generated from ${filename}\n\n`;
      let codeCellCount = 0;
      (cells || []).forEach((cell, index) => {
        if (cell.cell_type !== 'code') return;
        const trimmed = cell.source.replace(/\s+$/, '');
        if (!trimmed.trim()) return;
        codeCellCount += 1;
        source += `# ---- chickadee:cell ${index + 1} ----\n${trimmed}\n\n`;
      });
      return { source, codeCellCount };
    }),
    // Test seam for the shared classifier (real logic is RunnerCore/Swift,
    // covered by ScriptClassificationTests). This stub mirrors it, returning the
    // interpreter raw value so dispatch wiring can be exercised.
    runnerClassifyScript: options.runnerClassify ?? defaultClassifyStub,
    // Test seam for the shared loop + interpretation (real logic is
    // RunnerCore/Swift via wasm; this faithful double avoids the cross-realm
    // Promise hazard — see executeSuitesStub).
    runnerExecuteSuites: options.runnerExecuteSuites ?? executeSuitesStub,
    __CHICKADEE_BROWSER_RUNNER_TEST_HOOKS__: testHooks,
  };

  // Web-Worker executor seam.  By default the harness exposes NO Worker and no
  // factory override, so the runner falls back to the main-thread Pyodide path
  // (the rest of the suite exercises that).  When a test opts in via
  // `useGradingWorker`, install a fake-worker factory so the GradingWorkerExecutor
  // path runs without real Pyodide.
  // Every substrate is a Web Worker running a vendored xeus kernel — there is
  // no main-thread path any more (#1271), so the harness always installs the
  // fake worker unless a test is deliberately proving the Worker-less failover.
  // `useGradingWorker` is kept as an opt-OUT marker (`noWorker: true`) rather
  // than the old opt-in, since "no Worker" is now the exceptional case.
  let gradingWorkerFactory = null;
  if (!options.noWorker) {
    gradingWorkerFactory = options.workerFactory ?? makeFakeGradingWorkerFactory(options);
    context.__CHICKADEE_GRADING_WORKER_FACTORY__ = gradingWorkerFactory;
  }

  // Optional override for the GradingWorkerExecutor's bounded-init budget (read
  // once at module-eval from globalThis), so a timeout test runs in milliseconds.
  if (options.gradingInitTimeoutMs != null) {
    context.__CHICKADEE_GRADING_INIT_TIMEOUT_MS__ = options.gradingInitTimeoutMs;
  }

  context.window = {
    document,
    fetch: fetchImpl,
    loadPyodide: async () => py,
    JSZip: {
      async loadAsync() {
        return { files: zipEntries };
      },
    },
  };
  context.globalThis = context;

  // The two shared-semantics modules first (they define ChickadeeGradingShared
  // and ChickadeeRGradingShared, which the runner destructures at IIFE start),
  // then the runner — same order as _notebook-body.leaf loads them.
  const vmContext = vm.createContext(context);
  vm.runInContext(sharedSource, vmContext, { filename: 'grading-shared.js' });
  vm.runInContext(rSharedSource, vmContext, { filename: 'r-grading-shared.js' });
  vm.runInContext(runnerSource, vmContext, { filename: 'browser-runner.js' });

  return {
    context,
    window: context.window,
    hooks: testHooks.exports,
    statusEl,
    scriptLoads,
    postBodies,
    fetchCalls,
    breadcrumbs,
    py,
    gradingWorkerFactory,
  };
}

test('runAndSubmit executes Python scripts, posts a browser-wasm result collection, and cleans up workdir', async () => {
  const notebookJSON = JSON.stringify({
    nbformat: 4,
    metadata: {},
    cells: [
      { cell_type: 'code', source: ['answer = 42\n'], metadata: {} },
    ],
  });

  const harness = await loadRunnerHarness({
    zipFiles: {
      'tests/test_pass.py': '# pass\nJSON_RESULT_PASS\n',
      'tests/test_fail.py': '# fail\nJSON_RESULT_FAIL\n',
    },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 5,
      testSuites: [
        { script: 'tests/test_pass.py', tier: 'public' },
        { script: 'tests/test_fail.py', tier: 'secret' },
      ],
    },
    scriptBehaviors: {
      'tests/test_pass.py': {
        stdout: `${JSON.stringify({ shortResult: 'test_pass: passed', status: 'pass' })}\n`,
        stderr: '',
        exitCode: 0,
      },
      'tests/test_fail.py': {
        stdout: `${JSON.stringify({ shortResult: 'test_fail: failed', status: 'fail' })}\n`,
        stderr: 'traceback\n',
        exitCode: 1,
      },
    },
  });

  const result = await harness.window.BrowserRunner.runAndSubmit(
    new TextEncoder().encode(notebookJSON),
    'setup123',
  );

  assert.equal(result.outcomes.length, 2);
  assert.deepEqual(
    plain(result.outcomes.map(outcome => [outcome.testName, outcome.status])),
    [
      ['tests/test_pass', 'pass'],
      ['tests/test_fail', 'fail'],
    ],
  );

  assert.equal(harness.postBodies.length, 1);
  assert.equal(harness.postBodies[0].csrf, 'csrf-test-token');
  assert.equal(harness.postBodies[0].collection.runnerVersion, 'browser-wasm-runner/1.0');
  assert.equal(harness.postBodies[0].testSetupID, 'setup123');
  assert.ok(harness.postBodies[0].notebookText.includes('"answer = 42\\n"'));
  assert.equal(harness.statusEl.hidden, true);
  assert.equal(
    harness.gradingWorkerFactory.created.every(w => w.terminated),
    true,
    'dispose must terminate the grading worker, reclaiming the kernel',
  );
  assert.equal(
    harness.fetchCalls.filter(call => call.url.includes('/manifest')).length,
    1,
  );
});

test('runAndSubmit emits ordered submit-phase breadcrumbs; validation stays silent', async () => {
  const notebookJSON = JSON.stringify({
    nbformat: 4,
    metadata: {},
    cells: [{ cell_type: 'code', source: ['answer = 42\n'], metadata: {} }],
  });

  const harness = await loadRunnerHarness({
    zipFiles: { 'tests/test_pass.py': '# pass\nJSON_RESULT_PASS\n' },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 5,
      testSuites: [{ script: 'tests/test_pass.py', tier: 'public' }],
    },
    scriptBehaviors: {
      'tests/test_pass.py': {
        stdout: `${JSON.stringify({ shortResult: 'ok', status: 'pass' })}\n`,
        stderr: '',
        exitCode: 0,
      },
    },
  });

  await harness.window.BrowserRunner.runAndSubmit(
    new TextEncoder().encode(notebookJSON),
    'setup_bc',
  );

  // The breadcrumb funnel must cover the whole grading flow, in order, so a
  // freeze in any phase leaves a server-visible "last reached" record.
  // This case runs on the MAIN-THREAD executor (no useGradingWorker), so the
  // GradingWorkerExecutor's bounded-init breadcrumbs do not appear here; they are
  // covered by the worker-path test below.
  assert.deepEqual(
    harness.breadcrumbs.map(b => b.source),
    [
      'grading_start',
      'runtime_loaded',
      'setup_unpacked',
      'suite_started',
      'grading_init_start',
      'grading_init_done',
      'suite_done',
      'result_posting',
      'result_posted',
    ],
  );
  for (const b of harness.breadcrumbs) {
    assert.equal(b.kind, 'submit_phase');
    assert.equal(b.testSetupID, 'setup_bc');
    assert.match(b.message, /elapsed_ms=\d+/);
  }

  // The instructor validation path (runScripts without reportPhase) is silent —
  // breadcrumbs are scoped to actual student submissions.
  const validationHarness = await loadRunnerHarness({
    zipFiles: { 'test_ref.py': '# pass\nJSON_RESULT_PASS\n' },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 5,
      testSuites: [{ script: 'test_ref.py', tier: 'public' }],
    },
  });
  await validationHarness.window.BrowserRunner.runScripts(
    new TextEncoder().encode('answer = 42\n'),
    'setup_val',
    { filename: 'solution.py' },
  );
  assert.equal(validationHarness.breadcrumbs.length, 0);
});

test('runScripts validates a plain Python solution without posting a submission', async () => {
  const harness = await loadRunnerHarness({
    zipFiles: {
      'test_reference.py': '# pass\nJSON_RESULT_PASS\n',
    },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 5,
      testSuites: [
        { script: 'test_reference.py', tier: 'public' },
      ],
    },
  });

  const result = await harness.window.BrowserRunner.runScripts(
    new TextEncoder().encode('answer = 42\n'),
    'setup123',
    { filename: 'solution.py' },
  );

  assert.equal(result.outcomes.length, 1);
  assert.equal(result.outcomes[0].status, 'pass');
  assert.equal(result.collection.totalTests, 1);
  assert.equal(harness.postBodies.length, 0);
  const workerFiles = harness.gradingWorkerFactory.created[0].files;
  const hintWrite = { value: workerFiles['.chickadee_student_module'] };
  assert.equal(hintWrite && String(hintWrite.value), 'solution.py');
});

test('dependency failures are skipped without executing blocked scripts', async () => {
  const harness = await loadRunnerHarness({
    zipFiles: {
      'test_build.py': '# build\n',
      'test_unit.py': '# unit\n',
    },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 5,
      testSuites: [
        { script: 'test_build.py', tier: 'public' },
        { script: 'test_unit.py', tier: 'public', dependsOn: ['test_build.py'] },
      ],
    },
    scriptBehaviors: {
      'test_build.py': {
        stdout: `${JSON.stringify({ shortResult: 'test_build: failed', status: 'fail' })}\n`,
        stderr: '',
        exitCode: 1,
      },
    },
  });

  const result = await harness.window.BrowserRunner.runAndSubmit(
    new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
    'setup_dep',
  );

  assert.deepEqual(
    plain(result.outcomes.map(outcome => ({
      name: outcome.testName,
      status: outcome.status,
      shortResult: outcome.shortResult,
    }))),
    [
      { name: 'test_build', status: 'fail', shortResult: 'test_build: failed' },
      {
        name: 'test_unit',
        status: 'fail',
        // Pinned to the shared fixture so the browser producer can't drift from
        // the worker producer (skippedPrerequisiteMessage) or the parsers.
        shortResult: skipFixture.message,
      },
    ],
  );
  assert.deepEqual(
    harness.gradingWorkerFactory.created.flatMap(w => w.runCalls.map(c => c.script)),
    ['test_build.py']);
});

test('timeouts and unsupported script types are surfaced in outcomes', async () => {
  const harness = await loadRunnerHarness({
    zipFiles: {
      'test_slow.py': '# slow\n',
      'test_shell.sh': 'echo hi\n',
      'test_r.R': 'print("hi")\n',
    },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 0.001,
      testSuites: [
        { script: 'test_slow.py', tier: 'public' },
        { script: 'test_shell.sh', tier: 'public' },
        { script: 'test_r.R', tier: 'release' },
      ],
    },
    scriptBehaviors: {
      'test_slow.py': { pending: true },
    },
  });

  const result = await harness.window.BrowserRunner.runAndSubmit(
    new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
    'setup_timeout',
  );

  assert.deepEqual(
    plain(result.outcomes.map(outcome => [outcome.testName, outcome.status])),
    [
      ['test_slow', 'timeout'],
      ['test_shell', 'error'],
      ['test_r', 'pass'],
    ],
  );
  assert.equal(result.outcomes[0].shortResult, 'timed out');
  // Shell is the only kind with no substrate at all — it is reported per script
  // rather than aborting the grade, so the tests that CAN run still do.
  assert.match(result.outcomes[1].shortResult, /Shell scripts cannot run/);
  // R routes to its own kernel worker and grades normally alongside Python.
  assert.deepEqual(
    [...new Set(harness.gradingWorkerFactory.created.map(w => w.scriptPath))].sort(),
    ['/python-grading-worker.js', '/r-grading-worker.js'],
  );
});

test('GradingWorkerExecutor kills a CPU-bound run-away via terminate() and respawns for the next script', async () => {
  // The bug: with Pyodide on the MAIN thread, a synchronous CPU-bound infinite
  // loop in student code never yields to JS, so the Promise.race sleep timer
  // never fires — the tab froze and the submission was lost.  The fix moves
  // Pyodide into a Web Worker so the per-test timeout can call Worker.terminate()
  // to forcibly kill the run-away thread (no SIGKILL on the main thread, no
  // COOP/COEP needed), then spin up a fresh worker for the next script.
  //
  // The fake worker NEVER replies for the `{ pending: true }` script — a real
  // worker stuck in `while True: pass` would be exactly this unresponsive.  The
  // old main-thread code could not recover from this; the executor must time it
  // out (terminate), then grade the next script in a brand-new worker.
  const harness = await loadRunnerHarness({
    zipFiles: {
      'runaway.py': '# runaway\nJSON_RESULT_PASS\n',  // would "pass" if it ever returned
      'after.py': '# after\nJSON_RESULT_PASS\n',
    },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 0.05,  // small, so the run-away trips it fast
      testSuites: [
        { script: 'runaway.py', tier: 'public' },
        { script: 'after.py', tier: 'public' },
      ],
    },
    scriptBehaviors: {
      'runaway.py': { pending: true },  // hangs forever — never posts a reply
    },
  });

  const result = await harness.window.BrowserRunner.runAndSubmit(
    new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
    'setup_runaway',
  );

  // The hung script times out; the SUBSEQUENT script still grades — proving the
  // run-away didn't take the whole submission down with it.
  assert.deepEqual(
    plain(result.outcomes.map(outcome => [outcome.testName, outcome.status])),
    [
      ['runaway', 'timeout'],
      ['after', 'pass'],
    ],
  );
  assert.equal(result.outcomes[0].shortResult, 'timed out');

  // The kill path the old main-thread Promise.race could not provide: the first
  // worker was terminated (forcibly killed mid-run), and a SECOND worker was
  // spawned to grade `after.py`.
  const workers = harness.gradingWorkerFactory.created;
  assert.ok(workers.length >= 2, `expected a respawn after terminate, saw ${workers.length} worker(s)`);
  assert.ok(workers[0].terminated, 'the run-away worker must be terminated');
  // The fresh worker was re-initialized with the same workspace before running.
  assert.ok(workers[1].postedTypes.includes('init'), 'respawned worker must be re-init()ed');
  assert.ok(workers[1].postedTypes.includes('run'), 'respawned worker must run the next script');
});

test('GradingWorkerExecutor brackets the worker init with start/done breadcrumbs', async () => {
  // The init path (loadPyodide + env-config) used to be awaited with NO timer, so
  // a wedged boot hung the whole grade with zero telemetry. It is now bracketed
  // by grading_init_start/grading_init_done breadcrumbs (and bounded — see the
  // timeout test below) so a future init hang is localizable server-side via the
  // keepalive submit-phase funnel. Only the student submit path emits them
  // (runAndSubmit wires reportPhase; instructor validation stays silent).
  const harness = await loadRunnerHarness({
    zipFiles: { 'tests/test_pass.py': '# pass\nJSON_RESULT_PASS\n' },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 5,
      testSuites: [{ script: 'tests/test_pass.py', tier: 'public' }],
    },
    scriptBehaviors: {
      'tests/test_pass.py': {
        stdout: `${JSON.stringify({ shortResult: 'ok', status: 'pass' })}\n`,
        stderr: '',
        exitCode: 0,
      },
    },
  });

  await harness.window.BrowserRunner.runAndSubmit(
    new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
    'setup_init_bc',
  );

  const sources = harness.breadcrumbs.map(b => b.source);
  // Exactly one start/done pair (init is cached across the suite's scripts).
  assert.deepEqual(
    sources.filter(s => s.startsWith('grading_init')),
    ['grading_init_start', 'grading_init_done'],
  );
  // …and it brackets the run, between suite_started and suite_done.
  const ordered = ['suite_started', 'grading_init_start', 'grading_init_done', 'suite_done']
    .map(s => sources.indexOf(s));
  assert.ok(ordered.every((idx, i) => idx >= 0 && (i === 0 || idx > ordered[i - 1])),
    `init breadcrumbs out of order in ${JSON.stringify(sources)}`);
});

test('GradingWorkerExecutor bounds a wedged worker init: times out, retries once, then fails instead of hanging', async () => {
  // A worker whose init never replies (loadPyodide that never resolves — the
  // intermittent Pyodide-314 init hang) must NOT hang the grade forever. With a
  // tiny init budget the executor times out, terminates, retries once on a fresh
  // worker, and — when that also hangs — surfaces a bounded failure. Two
  // grading_init_start breadcrumbs (the attempts) prove the retry; the run never
  // exceeds the budget. This is the safety net the old unbounded init lacked.
  const harness = await loadRunnerHarness({
    initPending: true,          // fake worker never replies to 'init'
    gradingInitTimeoutMs: 25,   // tiny budget so the test is fast
    zipFiles: { 'tests/test_pass.py': '# pass\nJSON_RESULT_PASS\n' },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 5,
      testSuites: [{ script: 'tests/test_pass.py', tier: 'public' }],
    },
  });

  await assert.rejects(
    harness.window.BrowserRunner.runAndSubmit(
      new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
      'setup_init_hang',
    ),
    /init|configure Python/i,
  );

  const sources = harness.breadcrumbs.map(b => b.source);
  assert.equal(sources.filter(s => s === 'grading_init_start').length, 2, 'two init attempts');
  assert.equal(sources.filter(s => s === 'grading_init_failed').length, 2, 'both attempts reported failed');
  assert.ok(!sources.includes('grading_init_done'), 'init must not report done when it never succeeds');

  // Both spawned workers were terminated (the kill path on a wedged init).
  const workers = harness.gradingWorkerFactory.created;
  assert.equal(workers.length, 2, `expected two init attempts, saw ${workers.length}`);
  assert.ok(workers.every(w => w.terminated), 'every wedged init worker must be terminated');
});

test('a grading-runtime init failure fails over (throws, posts nothing) even when the wasm loop swallows run errors', async () => {
  // Regression guard for the Pyodide-3.14 WebKit grading break (the
  // `call_indirect to a null table entry` trap during env-config). The REAL
  // RunnerCore wasm catches a rejected run() and returns an exit-2 `error`
  // ScriptOutput (wasm/Sources/RunnerWasm/main.swift), so a grading-worker that
  // can't initialize would otherwise make executeSuites COMPLETE with an
  // all-`error` collection — which runAndSubmit posts as a real 0% result,
  // never reaching submitBrowserNotebook's server-failover catch. The init
  // probe in runScripts must THROW before the loop so the failover fires.
  //
  // The default executeSuitesStub re-throws a rejected run() (so the existing
  // "bounds a wedged worker init" test passes via the stub) — which HIDES this
  // production gap. Here we model the wasm's swallowing faithfully: an
  // executeSuites that resolves with error outcomes and NEVER rejects. The
  // probe must still reject, and crucially must post NO browser result.
  const swallowingExecuteSuites = (suites) => Promise.resolve(
    suites.map((s) => ({
      testName: s.script, testClass: null, tier: s.tier, status: 'error',
      shortResult: 'browser executor: script run rejected', longResult: null,
      points: 1, executionTimeMs: 0, memoryUsageBytes: null,
      attemptNumber: 1, isFirstPassSuccess: false,
    })),
  );

  const harness = await loadRunnerHarness({
    initPending: true,          // worker init never replies → init fails
    gradingInitTimeoutMs: 25,   // tiny budget so the test is fast
    runnerExecuteSuites: swallowingExecuteSuites,
    zipFiles: { 'tests/test_pass.py': '# pass\nJSON_RESULT_PASS\n' },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 5,
      testSuites: [{ script: 'tests/test_pass.py', tier: 'public' }],
    },
  });

  await assert.rejects(
    harness.window.BrowserRunner.runAndSubmit(
      new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
      'setup_init_trap',
    ),
    /initialize|init/i,
  );

  // The whole point: a failed grading runtime must NOT post a 0% browser result.
  // The submission belongs to the server-side failover backstop instead.
  assert.equal(harness.postBodies.length, 0, 'a failed init must not post a browser result');
});

test('Python is graded on the xeus-python kernel worker', async () => {
  // Since #1271 there is one Python substrate. Both workers speak the same
  // protocol, so the executor does not change — only the script it spawns.
  const harness = await loadRunnerHarness({
    zipFiles: { 'test_pass.py': '# pass\nJSON_RESULT_PASS\n' },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 10,
      testSuites: [{ script: 'test_pass.py', tier: 'public' }],
    },
  });

  const result = await harness.window.BrowserRunner.runAndSubmit(
    new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
    'setup_xeus',
  );

  assert.deepEqual(plain(result.outcomes.map(o => [o.testName, o.status])), [['test_pass', 'pass']]);
  assert.deepEqual(
    harness.gradingWorkerFactory.created.map(w => w.scriptPath),
    ['/python-grading-worker.js'],
  );
});


test('R is graded on its own kernel worker, never the Python one', async () => {
  // R has exactly one browser substrate; a Python rollout knob must not touch
  // it. Both languages on xeus is the end state, but they get there separately.
  const harness = await loadRunnerHarness({
    zipFiles: { 'publictest_a.R': 'source("test_runtime.R")\nJSON_RESULT_PASS\n' },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 10,
      testSuites: [{ script: 'publictest_a.R', tier: 'public' }],
    },
  });

  await harness.window.BrowserRunner.runAndSubmit(
    new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
    'setup_r_under_xeus',
  );

  assert.deepEqual(
    harness.gradingWorkerFactory.created.map(w => w.scriptPath),
    ['/r-grading-worker.js'],
  );
});

test('a browser with no Worker fails the grade over instead of guessing', async () => {
  // There is no main-thread path any more: a xeus kernel needs importScripts,
  // which is worker-only, and the old Pyodide fallback could not kill a
  // CPU-bound runaway anyway. Failing over to the native worker is slower and
  // correct; grading on a different runtime would not be.
  const harness = await loadRunnerHarness({
    noWorker: true,
    zipFiles: { 'test_pass.py': '# pass\nJSON_RESULT_PASS\n' },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 10,
      testSuites: [{ script: 'test_pass.py', tier: 'public' }],
    },
  });

  await assert.rejects(
    harness.window.BrowserRunner.runAndSubmit(
      new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
      'setup_xeus_no_worker',
    ),
    /Web Worker support/,
  );
  assert.equal(harness.postBodies.length, 0, 'a failed init must not post a browser result');
});

test('an R test script is graded on the xeus-r substrate, and Pyodide is never booted', async () => {
  // The capability #1271 exists for. Before it, RoutingExecutor did not exist
  // and every .R script came back as an error outcome reading "R test scripts
  // require WebR" — R assignments could only be graded by the native worker.
  const harness = await loadRunnerHarness({
    zipFiles: {
      'publictest_bmi.R': 'source("test_runtime.R")\nJSON_RESULT_PASS\n',
      'releasetest_edge.R': 'source("test_runtime.R")\nJSON_RESULT_FAIL\n',
    },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 10,
      testSuites: [
        { script: 'publictest_bmi.R', tier: 'public' },
        { script: 'releasetest_edge.R', tier: 'release' },
      ],
    },
  });

  const result = await harness.window.BrowserRunner.runAndSubmit(
    new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
    'setup_r',
  );

  assert.deepEqual(
    plain(result.outcomes.map(o => [o.testName, o.status])),
    [['publictest_bmi', 'pass'], ['releasetest_edge', 'fail']],
  );

  // One worker, and it is the R one. An R lab must not pay to download and boot
  // Pyodide for tests that will never touch it.
  const paths = harness.gradingWorkerFactory.created.map(w => w.scriptPath);
  assert.deepEqual(paths, ['/r-grading-worker.js']);
});

test('a Python assignment never boots the R kernel', async () => {
  // The mirror of the case above: the 52 MB chickadee-r environment must not be
  // fetched for an assignment with no R in it.
  const harness = await loadRunnerHarness({
    zipFiles: { 'test_pass.py': '# pass\nJSON_RESULT_PASS\n' },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 10,
      testSuites: [{ script: 'test_pass.py', tier: 'public' }],
    },
  });

  await harness.window.BrowserRunner.runAndSubmit(
    new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
    'setup_py',
  );

  const paths = harness.gradingWorkerFactory.created.map(w => w.scriptPath);
  assert.deepEqual(paths, ['/python-grading-worker.js']);
});

test('test_runtime.R is written into every grading workspace', async () => {
  // An R test script opens with source("test_runtime.R"); the helper has to be
  // in the workspace the substrate materializes, exactly as the native runner's
  // writeRRuntimeHelper puts it in the test setup directory.
  const harness = await loadRunnerHarness({
    zipFiles: { 'publictest_a.R': 'source("test_runtime.R")\nJSON_RESULT_PASS\n' },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 10,
      testSuites: [{ script: 'publictest_a.R', tier: 'public' }],
    },
  });

  await harness.window.BrowserRunner.runAndSubmit(
    new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
    'setup_r_runtime',
  );

  const worker = harness.gradingWorkerFactory.created[0];
  assert.ok(worker.files['test_runtime.R'], 'test_runtime.R must reach the R workspace');
  assert.match(String(worker.files['test_runtime.R']), /chickadee_student_file/);
});

test('an R assignment gets _ck_inputs.R, not _ck_inputs.py', async () => {
  // The seed endpoint already resolves each personalization value as a literal
  // in the assignment's language; only the wrapper file differs. Writing the
  // Python form for an R assignment — which is what the pre-#1271 runner did —
  // left every personalized R test reading an empty chickadee_inputs().
  const harness = await loadRunnerHarness({
    zipFiles: { 'publictest_a.R': 'source("test_runtime.R")\nJSON_RESULT_PASS\n' },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 10,
      testSuites: [{ script: 'publictest_a.R', tier: 'public' }],
    },
    assignmentSeed: 'abc123',
    assignmentLanguage: 'r',
    personalizedInputs: { threshold: '42' },
  });

  await harness.window.BrowserRunner.runAndSubmit(
    new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
    'setup_r_inputs',
  );

  const worker = harness.gradingWorkerFactory.created[0];
  assert.equal(worker.files['_ck_inputs.py'], undefined, 'an R assignment must not get the Python inputs file');
  assert.match(String(worker.files['_ck_inputs.R']), /\.ck_inputs <- list\(/);
  assert.match(String(worker.files['_ck_inputs.R']), /`threshold` = 42/);
});

test('GradingWorkerExecutor grades pass/fail through one worker and classifies non-python on the main thread', async () => {
  // Happy path of the worker executor: one worker is spawned and re-used for
  // every python script (no terminate), pass/fail are graded from the worker's
  // RAW output, and a shell script is rejected on the MAIN thread without ever
  // touching the worker (its 'run' never reaches the worker).
  const harness = await loadRunnerHarness({
    zipFiles: {
      'test_pass.py': '# pass\nJSON_RESULT_PASS\n',
      'test_fail.py': '# fail\nJSON_RESULT_FAIL\n',
      'test_shell.sh': 'echo hi\n',
    },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 5,
      testSuites: [
        { script: 'test_pass.py', tier: 'public' },
        { script: 'test_fail.py', tier: 'public' },
        { script: 'test_shell.sh', tier: 'public' },
      ],
    },
  });

  const result = await harness.window.BrowserRunner.runAndSubmit(
    new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
    'setup_worker_happy',
  );

  assert.deepEqual(
    plain(result.outcomes.map(outcome => [outcome.testName, outcome.status])),
    [
      ['test_pass', 'pass'],
      ['test_fail', 'fail'],
      ['test_shell', 'error'],
    ],
  );
  assert.match(result.outcomes[2].shortResult, /Shell scripts cannot run/);

  // Exactly one worker, never terminated mid-run (dispose() at the end may
  // terminate it, which is fine) — and the shell script was classified on the
  // main thread, so the worker only ever ran the two python scripts.
  const workers = harness.gradingWorkerFactory.created;
  assert.equal(workers.length, 1, 'a non-timing-out run reuses one worker');
  const runCount = workers[0].postedTypes.filter(t => t === 'run').length;
  assert.equal(runCount, 2, 'only the two python scripts reached the worker (shell handled on main thread)');
  assert.equal(harness.postBodies.length, 1, 'results are still posted');
});

test('per-script timeLimitSeconds in the manifest overrides the assignment default for that script', async () => {
  // The assignment default is 12s; `slow.py` carries a 3s per-test override.
  // The override must be the limit handed to the executor for `slow.py`, while
  // `fast.py` (no override) still gets the assignment default.
  const harness = await loadRunnerHarness({
    zipFiles: {
      'slow.py': '# slow\nJSON_RESULT_PASS\n',
      'fast.py': '# fast\nJSON_RESULT_PASS\n',
    },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 12,
      testSuites: [
        { script: 'slow.py', tier: 'public', timeLimitSeconds: 3 },
        { script: 'fast.py', tier: 'public' },
      ],
    },
  });

  await harness.window.BrowserRunner.runAndSubmit(
    new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
    'setup_per_test_limit',
  );

  // The happy path reuses one worker; its runCalls record the { script, limit }
  // each script was launched with — the override is applied before executor.run.
  const worker = harness.gradingWorkerFactory.created[0];
  const limitFor = name => worker.runCalls.find(c => c.script === name)?.limit;
  assert.equal(limitFor('slow.py'), 3, 'the per-script override is the limit for slow.py');
  assert.equal(limitFor('fast.py'), 12, 'an override-less script keeps the assignment default');
});

test('extensionless Python test scripts dispatch via their shebang instead of failing as unsupported', async () => {
  const harness = await loadRunnerHarness({
    zipFiles: {
      // A generated test script with no file extension whose first line is a
      // Python shebang — the shape produced by the variableEquality template.
      'beats': '#!/usr/bin/env python3\nvariable_name = "beats"\nJSON_RESULT_PASS\n',
      // Extensionless file with a shell shebang stays a (browser-unsupported) shell.
      'runtests': '#!/bin/sh\necho hi\n',
      // No extension, no shebang, nothing Python-looking → genuinely unsupported.
      'mystery': 'just some text\n',
    },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 5,
      testSuites: [
        { script: 'beats', tier: 'public' },
        { script: 'runtests', tier: 'public' },
        { script: 'mystery', tier: 'public' },
      ],
    },
  });

  const result = await harness.window.BrowserRunner.runAndSubmit(
    new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
    'setup_extensionless',
  );

  assert.deepEqual(
    plain(result.outcomes.map(outcome => [outcome.testName, outcome.status])),
    [
      ['beats', 'pass'],
      ['runtests', 'error'],
      ['mystery', 'error'],
    ],
  );
  // The extensionless Python script actually executed (it was compiled).
  assert.ok(harness.gradingWorkerFactory.created
    .flatMap(w => w.runCalls.map(c => c.script)).includes('beats'));
  assert.match(result.outcomes[1].shortResult, /Shell scripts cannot run/);
  assert.match(result.outcomes[2].shortResult, /Unsupported test script type: mystery/);
});

test('browser produces canonical worker-shaped outcomes (display name -> testName, no bespoke fields)', async () => {
  // Post-migration the browser emits the SAME TestOutcome shape the worker does
  // — testName is the display name (falling back to the script stem), and the
  // result strings come from the shared interpretScriptOutput (footer
  // shortResult; stdout/stderr → longResult). The browser-only fields
  // (scriptName, displayName) and the bespoke JSON-envelope field extraction
  // (error/traceback/exception) are gone — both runners are now identical.
  const harness = await loadRunnerHarness({
    zipFiles: {
      'test_q1_bmi.py': '# q1\n',
    },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 5,
      testSuites: [
        { script: 'test_q1_bmi.py', tier: 'public', name: 'Q1: BMI Calculation' },
      ],
    },
    scriptBehaviors: {
      'test_q1_bmi.py': {
        stdout: `${JSON.stringify({
          shortResult: 'Q1: BMI Calculation: Could not test calculate_bmi',
          status: 'error',
        })}\n`,
        stderr: 'Traceback (most recent call last):\nNotImplementedError: Implement calculate_bmi\n',
        exitCode: 2,
      },
    },
  });

  const result = await harness.window.BrowserRunner.runAndSubmit(
    new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
    'setup_q1',
  );

  assert.deepEqual(
    plain(result.outcomes[0]),
    {
      testName: 'Q1: BMI Calculation',
      testClass: null,
      tier: 'public',
      status: 'error',
      shortResult: 'Q1: BMI Calculation: Could not test calculate_bmi',
      longResult: 'stderr:\nTraceback (most recent call last):\nNotImplementedError: Implement calculate_bmi',
      points: 1,
      executionTimeMs: result.outcomes[0].executionTimeMs,
      memoryUsageBytes: null,
      attemptNumber: 1,
      isFirstPassSuccess: false,
    },
  );
});

test('manifest and setup download failures bubble up with browser-runner context', async () => {
  const manifestHarness = await loadRunnerHarness({
    zipFiles: {},
    manifestFetchResponse: {
      ok: false,
      status: 403,
      async text() {
        return 'Forbidden';
      },
    },
  });

  await assert.rejects(
    manifestHarness.window.BrowserRunner.runAndSubmit(
      new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
      'setup_forbidden',
    ),
    /Failed to load test configuration: Fetch failed 403/,
  );

  const downloadHarness = await loadRunnerHarness({
    downloadError: new Error('network down'),
  });

  await assert.rejects(
    downloadHarness.window.BrowserRunner.runAndSubmit(
      new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
      'setup_download',
    ),
    /Failed to download test setup: network down/,
  );
});

test('extractNotebook delegates Python to RunnerCore (module + introspectable sidecar + hints) and keeps R on the JS path', async () => {
  // The per-cell extraction logic now lives in RunnerCore (Swift/wasm) and is
  // covered by Tests/WorkerTests/NotebookExtractionTests.swift. Here we assert
  // the browser glue: cells handed to the shared extractor, and its outputs
  // (executable module + introspectable-source sidecar) written with hints.
  let received = null;
  const harness = await loadRunnerHarness({
    runnerExtractor: (cells, filename) => {
      received = { cells, filename };
      return {
        executableModule: '# exec module\nMODULE_BODY\n',
        introspectableSource: '# real source\ndef tax():\n    pass\n',
        codeCellCount: cells.filter(c => c.cell_type === 'code').length,
      };
    },
  });
  const { extractNotebook } = harness.hooks;

  harness.py.FS.mkdir('/course');
  await extractNotebook(
    harness.py,
    '/course',
    'submission.ipynb',
    JSON.stringify({
      nbformat: 4,
      metadata: { kernelspec: { name: 'python3' } },
      cells: [
        { cell_type: 'markdown', source: ['ignore'], metadata: {} },
        { cell_type: 'code', source: ['x = 1\n'], metadata: {} },
      ],
    }),
  );

  // Cells passed through to the shared extractor (source joined, type preserved).
  assert.equal(received.filename, 'submission.ipynb');
  assert.deepEqual(plain(received.cells), [
    { cell_type: 'markdown', source: 'ignore' },
    { cell_type: 'code', source: 'x = 1\n' },
  ]);
  // Executable module + introspectable sidecar both written, with both hints.
  assert.equal(
    harness.py.FS.readFile('/course/submission.py', { encoding: 'utf8' }),
    '# exec module\nMODULE_BODY\n',
  );
  assert.equal(
    harness.py.FS.readFile('/course/submission.source.py', { encoding: 'utf8' }),
    '# real source\ndef tax():\n    pass\n',
  );
  assert.equal(
    harness.py.FS.readFile('/course/.chickadee_student_module', { encoding: 'utf8' }),
    'submission.py',
  );
  assert.equal(
    harness.py.FS.readFile('/course/.chickadee_student_source', { encoding: 'utf8' }),
    'submission.source.py',
  );

  // R extracts through the shared extractR seam (marker-bearing, matching the
  // native worker); no introspectable sidecar for R.
  await extractNotebook(
    harness.py,
    '/course',
    'lab.ipynb',
    JSON.stringify({
      nbformat: 4,
      metadata: { kernelspec: { name: 'webr' }, language_info: { name: 'r' } },
      cells: [{ cell_type: 'code', source: ['x <- 2\n'], metadata: {} }],
    }),
  );
  assert.equal(
    harness.py.FS.readFile('/course/lab.R', { encoding: 'utf8' }),
    '# Generated from lab.ipynb\n\n# ---- chickadee:cell 1 ----\nx <- 2\n\n',
  );
  assert.equal(
    harness.py.FS.readFile('/course/.chickadee_student_module', { encoding: 'utf8' }),
    'lab.R',
  );
});

test('R notebook extraction feeds the extractR seam cells + filename and writes its result verbatim', async () => {
  // Override the harness's faithful double with a capturing stub: proves the
  // browser glue hands the projected cells straight to the shared extractor
  // (RunnerCore.extractR via wasm in production) and writes whatever it
  // returns, transforming nothing itself.
  let received = null;
  const harness = await loadRunnerHarness({
    runnerExtractR: (cells, filename) => {
      received = { cells, filename };
      return {
        source: `# Generated from ${filename}\n\n# ---- chickadee:cell 1 ----\nx <- 2\n\n`,
        codeCellCount: 1,
      };
    },
  });
  const { extractNotebook } = harness.hooks;

  harness.py.FS.mkdir('/course');
  await extractNotebook(
    harness.py,
    '/course',
    'lab.ipynb',
    JSON.stringify({
      nbformat: 4,
      metadata: { kernelspec: { name: 'ir' } },
      cells: [
        { cell_type: 'markdown', source: ['notes'], metadata: {} },
        { cell_type: 'code', source: ['x <- 2\n'], metadata: {} },
      ],
    }),
  );

  // Cells passed through with type preserved (marker numbering needs the
  // markdown cell's position), and the wasm result written verbatim.
  assert.equal(received.filename, 'lab.ipynb');
  assert.deepEqual(plain(received.cells), [
    { cell_type: 'markdown', source: 'notes' },
    { cell_type: 'code', source: 'x <- 2\n' },
  ]);
  assert.equal(
    harness.py.FS.readFile('/course/lab.R', { encoding: 'utf8' }),
    '# Generated from lab.ipynb\n\n# ---- chickadee:cell 1 ----\nx <- 2\n\n',
  );
  assert.equal(
    harness.py.FS.readFile('/course/.chickadee_student_module', { encoding: 'utf8' }),
    'lab.R',
  );
});

test('failure detail strips the trailing JSON envelope so students never see the raw payload', async () => {
  const errorText = 'Variable `age` is not defined in the student notebook.\n'
    + '  expected: a module-level variable named `age`\n';
  const jsonFooter = JSON.stringify({
    shortResult: 'Test: `age` is defined: Variable `age` is not defined in the student notebook.',
    status: 'fail',
    test: 'Test: `age` is defined',
    error: errorText,
  });

  const harness = await loadRunnerHarness({
    zipFiles: { 'publictest_age.py': '# Test: `age` is defined\n' },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 5,
      testSuites: [
        { script: 'publictest_age.py', tier: 'public', name: 'Test: `age` is defined' },
      ],
    },
    scriptBehaviors: {
      'publictest_age.py': {
        stdout: `${errorText}${jsonFooter}\n`,
        stderr: '',
        exitCode: 1,
      },
    },
  });

  const result = await harness.window.BrowserRunner.runAndSubmit(
    new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
    'setup_age',
  );

  const outcome = result.outcomes[0];
  assert.equal(outcome.status, 'fail');
  assert.ok(!outcome.longResult.includes('"shortResult"'), 'JSON envelope must be stripped from longResult');
  assert.ok(!outcome.longResult.includes('{'), 'no JSON braces should remain in student-facing detail');
  // Shared interpretScriptOutput strips the JSON footer line, then presents the
  // remaining stdout under a "stdout:" section header — identical to the worker.
  assert.equal(
    outcome.longResult,
    'stdout:\nVariable `age` is not defined in the student notebook.\n  expected: a module-level variable named `age`',
  );
});

test('injects the per-student seed into os.environ for parity with the native worker', async () => {
  // The worker sets CHICKADEE_ASSIGNMENT_SEED in the test subprocess
  // (RunnerDaemon+JobProcessing). The browser must do the same so a test that
  // reads the seed grades identically. The runner fetches the seed endpoint and
  // sets os.environ before any script runs.
  const harness = await loadRunnerHarness({
    assignmentSeed: 'deadbeefcafe0123',
    zipFiles: { 'test_seed.py': '# seed\nJSON_RESULT_PASS\n' },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 5,
      testSuites: [{ script: 'test_seed.py', tier: 'public' }],
    },
  });

  await harness.window.BrowserRunner.runAndSubmit(
    new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
    'setup_seed',
  );

  // The seed now reaches the substrate over the worker's init message rather
  // than through a main-thread Pyodide handle.
  assert.equal(harness.gradingWorkerFactory.created[0].seed, 'deadbeefcafe0123');
  assert.equal(
    harness.fetchCalls.filter(call => call.url.endsWith('/seed')).length,
    1,
    'the seed endpoint should be fetched exactly once',
  );
});

test('omits CHICKADEE_ASSIGNMENT_SEED when the assignment is not personalized (null seed)', async () => {
  // A null seed (no owning assignment / non-personalized setup, or an older
  // server) must leave the env var unset, preserving legacy behaviour.
  const harness = await loadRunnerHarness({
    assignmentSeed: null,
    zipFiles: { 'test_seed.py': '# seed\nJSON_RESULT_PASS\n' },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 5,
      testSuites: [{ script: 'test_seed.py', tier: 'public' }],
    },
  });

  await harness.window.BrowserRunner.runAndSubmit(
    new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
    'setup_noseed',
  );

  assert.equal(harness.py.state.assignmentSeedEnv, null);
});

test('writes _ck_inputs.py from the seed endpoint personalizedInputs (parity with the worker)', async () => {
  // The worker writes _ck_inputs.py into the grading workspace from
  // Job.personalizedInputs; the browser must do the same from the seed
  // endpoint's personalizedInputs so a generated pattern-family script that
  // loads per-student args/expected grades identically. Values are verbatim
  // Python literals (repr) the server resolved for this student's seed.
  const harness = await loadRunnerHarness({
    assignmentSeed: 'deadbeefcafe0123',
    personalizedInputs: { adults_expected: '2', patients: "[{'mrn': '1001'}]" },
    zipFiles: { 'publictest_x.py': '# x\nJSON_RESULT_PASS\n' },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 5,
      testSuites: [{ script: 'publictest_x.py', tier: 'public' }],
    },
  });

  await harness.window.BrowserRunner.runAndSubmit(
    new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
    'setup_personalized',
  );

  // The file map is handed to the substrate over the worker's init message.
  const src = String(harness.gradingWorkerFactory.created[0].files['_ck_inputs.py'] ?? '');
  assert.ok(src, '_ck_inputs.py must reach the grading workspace');
  assert.ok(src.includes('_ck = {'), 'emits a _ck dict');
  assert.ok(src.includes('"adults_expected": 2,'), 'value inserted verbatim');
  assert.ok(src.includes(`"patients": [{'mrn': '1001'}],`), 'Python-literal value preserved');
  // Keys sorted for determinism (adults_expected before patients).
  assert.ok(src.indexOf('adults_expected') < src.indexOf('patients'));
});

test('omits _ck_inputs.py when the seed endpoint returns no personalizedInputs', async () => {
  const harness = await loadRunnerHarness({
    assignmentSeed: 'deadbeefcafe0123',
    zipFiles: { 'publictest_x.py': '# x\nJSON_RESULT_PASS\n' },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 5,
      testSuites: [{ script: 'publictest_x.py', tier: 'public' }],
    },
  });

  await harness.window.BrowserRunner.runAndSubmit(
    new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
    'setup_noinputs',
  );

  assert.equal(
    harness.py.FS.writes.find(w => w.targetPath.endsWith('/_ck_inputs.py')),
    undefined,
    'no _ck_inputs.py when there are no per-student inputs',
  );
});

// ── Section grouping (results displayed per test-suite section) ──────────────
// The browser-graded results views (notebook.js, assignment-validate.js) group
// outcomes into one table per section, matching the server-rendered submission
// view (submission.leaf).  The runner supplies the data — the ordered section
// list plus a sectionID parallel to the outcomes — and the shared
// BrowserRunner.groupBySection buckets them, mirroring the server's
// groupOutcomesBySection (Tests/APITests/SectionsTests.swift).

test('runScripts surfaces ordered sections + a sectionID parallel to outcomes; outcomes stay canonical', async () => {
  const passing = exit => ({ stdout: '', stderr: '', exitCode: exit });
  const harness = await loadRunnerHarness({
    zipFiles: { 'a.py': '# a\n', 'b.py': '# b\n', 'c.py': '# c\n' },
    manifest: {
      gradingMode: 'browser',
      timeLimitSeconds: 5,
      sections: [
        { id: 's1', name: 'Question 1' },
        { id: 's2', name: 'Question 2' },
      ],
      testSuites: [
        { script: 'a.py', tier: 'public', sectionID: 's1' },
        { script: 'b.py', tier: 'public', sectionID: 's2' },
        { script: 'c.py', tier: 'public' },
      ],
    },
    scriptBehaviors: { 'a.py': passing(0), 'b.py': passing(0), 'c.py': passing(0) },
  });

  const result = await harness.window.BrowserRunner.runScripts(
    new TextEncoder().encode('{"nbformat":4,"metadata":{},"cells":[]}'),
    'setup_sections',
  );

  // Ordered section list (id + name), straight from the manifest.
  assert.deepEqual(plain(result.sections), [
    { id: 's1', name: 'Question 1' },
    { id: 's2', name: 'Question 2' },
  ]);
  // sectionIDs[i] is the section of outcomes[i] (c.py is ungrouped -> null).
  assert.deepEqual(plain(result.sectionIDs), ['s1', 's2', null]);
  // The outcome objects themselves must NOT carry a sectionID — they stay the
  // canonical worker TestOutcome shape (guarded above for the single-outcome
  // case; this is the multi-section regression guard).
  for (const outcome of result.outcomes) {
    assert.ok(!Object.hasOwn(outcome, 'sectionID'), 'outcome must not carry a sectionID field');
  }
});

test('groupBySection buckets outcomes in section order with a trailing Ungrouped block', async () => {
  const harness = await loadRunnerHarness({ manifest: { gradingMode: 'browser', testSuites: [] } });
  const { groupBySection } = harness.window.BrowserRunner;

  const sections = [{ id: 's1', name: 'One' }, { id: 's2', name: 'Two' }];
  const outcomes = ['a', 'b', 'c', 'd'].map(n => ({ testName: n }));
  // d -> null => Ungrouped; matches SectionsTests.groupOutcomesEmits...Ungrouped.
  const grouped = groupBySection(outcomes, sections, ['s1', 's2', 's1', null]);

  // plain() normalises cross-realm objects returned from the vm context.
  assert.deepEqual(
    plain(grouped.map(g => ({ name: g.sectionName, tests: g.outcomes.map(o => o.testName) }))),
    [
      { name: 'One', tests: ['a', 'c'] },
      { name: 'Two', tests: ['b'] },
      { name: 'Ungrouped', tests: ['d'] },
    ],
  );
});

test('groupBySection with no sections is a single unlabelled bucket (legacy flat table)', async () => {
  const harness = await loadRunnerHarness({ manifest: { gradingMode: 'browser', testSuites: [] } });
  const { groupBySection } = harness.window.BrowserRunner;

  const outcomes = [{ testName: 'a' }, { testName: 'b' }];
  const grouped = groupBySection(outcomes, [], [null, null]);

  assert.equal(grouped.length, 1);
  assert.equal(grouped[0].sectionName, null, 'no sections => unlabelled bucket, identical to pre-sections layout');
  assert.deepEqual(plain(grouped[0].outcomes.map(o => o.testName)), ['a', 'b']);
});

test('groupBySection keeps identical display names in their own sections (v0.4.105 index correlation)', async () => {
  const harness = await loadRunnerHarness({ manifest: { gradingMode: 'browser', testSuites: [] } });
  const { groupBySection } = harness.window.BrowserRunner;

  // Two pattern-family cases sharing the label "Test 1" in different sections.
  // A name-keyed map would collapse both onto one section; index correlation
  // via the parallel sectionIDs array keeps them apart.
  const sections = [{ id: 'warmup', name: 'Warm Up' }, { id: 'warmup2', name: 'Warm Up II' }];
  const outcomes = [{ testName: 'Test 1' }, { testName: 'Test 1' }];
  const grouped = groupBySection(outcomes, sections, ['warmup', 'warmup2']);

  assert.deepEqual(
    plain(grouped.map(g => ({ name: g.sectionName, n: g.outcomes.length }))),
    [{ name: 'Warm Up', n: 1 }, { name: 'Warm Up II', n: 1 }],
  );
});

test('groupBySection sends a stale/unknown sectionID to the Ungrouped block', async () => {
  const harness = await loadRunnerHarness({ manifest: { gradingMode: 'browser', testSuites: [] } });
  const { groupBySection } = harness.window.BrowserRunner;

  const sections = [{ id: 's1', name: 'One' }];
  // outcomes[1] points at a section no longer in the manifest.
  const grouped = groupBySection([{ testName: 'a' }, { testName: 'b' }], sections, ['s1', 's-gone']);

  assert.deepEqual(
    plain(grouped.map(g => ({ name: g.sectionName, tests: g.outcomes.map(o => o.testName) }))),
    [
      { name: 'One', tests: ['a'] },
      { name: 'Ungrouped', tests: ['b'] },
    ],
  );
});

// Regression: Pyodide's loadPackagesFromImports only scans the source string it
// is handed and does not follow imports into local modules. A test script that
// imports a bundled helper which itself imports numpy therefore ran with numpy
// unloaded — green on the native validation run (numpy installed system-wide),
// ModuleNotFoundError for every student in the browser.

