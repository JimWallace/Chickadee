import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const runnerSource = await fs.readFile(
  path.resolve('Public/browser-runner.js'),
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
  const byExt = { py: 'python', sh: 'sh', bash: 'bash', zsh: 'zsh', rb: 'ruby', pl: 'perl', js: 'node', php: 'php', r: 'rscript' };
  if (byExt[ext]) return byExt[ext];
  const first = String(source || '').replace(/^[﻿\s]+/, '').split('\n', 1)[0] || '';
  if (first.startsWith('#!')) {
    const lo = first.toLowerCase();
    if (lo.includes('python')) return 'python';
    if (lo.includes('node') || lo.includes('javascript')) return 'node';
    if (lo.includes('ruby')) return 'ruby';
    if (lo.includes('perl')) return 'perl';
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
function longResultOf(raw, footer) {
  let stdout = String(raw.stdout || '');
  if (footer) {
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
  if (raw.timedOut) return { status: 'timeout', shortResult: 'timed out', longResult: longResultOf(raw, false) };
  const status = raw.exitCode === 0 ? 'pass' : (raw.exitCode === 1 || raw.exitCode === 3) ? 'fail' : 'error';
  const lines = String(raw.stdout || '').split('\n').map(l => l.trim()).filter(Boolean);
  const last = lines[lines.length - 1] || '';
  let footer = false;
  let shortResult;
  if (last) {
    try {
      const obj = JSON.parse(last);
      if (obj && typeof obj === 'object' && !Array.isArray(obj)) {
        footer = true;
        shortResult = typeof obj.shortResult === 'string' ? obj.shortResult : defaultShort(status);
      }
    } catch (_) { /* not a JSON footer */ }
  }
  if (shortResult === undefined) shortResult = last || defaultShort(status);
  return { status, shortResult, longResult: longResultOf(raw, footer) };
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
  };

  const py = {
    FS: fs,
    state,
    async loadPackagesFromImports(src) {
      state.loadPackageCalls.push(src);
      if (options.packageError) throw options.packageError;
    },
    async runPythonAsync(code) {
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

async function loadRunnerHarness(options = {}) {
  const statusEl = { hidden: true, textContent: '', className: '' };
  const scriptLoads = [];
  const postBodies = [];
  const fetchCalls = [];
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
    getCsrfToken: () => options.csrfToken ?? 'csrf-test-token',
    document,
    // Test seam: preset the RunnerCore extractor so the runner never loads the
    // real wasm bundle. The actual extraction logic is covered by the Swift
    // RunnerCore tests; here a stub returns deterministic output.
    runnerExtractPython: options.runnerExtractor ?? ((cells, filename) => ({
      executableModule: `# Generated from ${filename}\n# (stub executable module)\n`,
      introspectableSource: `# Generated from ${filename}\n# (stub introspectable source)\n`,
      codeCellCount: (cells || []).filter(c => c.cell_type === 'code').length,
    })),
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

  vm.runInNewContext(runnerSource, context, { filename: 'browser-runner.js' });

  return {
    context,
    window: context.window,
    hooks: testHooks.exports,
    statusEl,
    scriptLoads,
    postBodies,
    fetchCalls,
    py,
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
    [...harness.py.FS.entries.keys()].some(key => key.startsWith('/chickadee_work_')),
    false,
  );
  assert.equal(
    harness.fetchCalls.filter(call => call.url.includes('/manifest')).length,
    1,
  );
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
  const hintWrite = harness.py.FS.writes.find(write => write.targetPath.endsWith('/.chickadee_student_module'));
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
  assert.deepEqual(harness.py.state.configuredScripts, ['test_build.py']);
});

test('timeouts and unsupported script types are surfaced in outcomes', async () => {
  const harness = await loadRunnerHarness({
    zipFiles: {
      'test_slow.py': '# slow\n',
      'test_shell.sh': 'echo hi\n',
      'test_r.R': 'print(\"hi\")\n',
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
      ['test_r', 'error'],
    ],
  );
  assert.equal(result.outcomes[0].shortResult, 'timed out');
  assert.match(result.outcomes[1].shortResult, /Shell scripts cannot run/);
  assert.match(result.outcomes[2].shortResult, /WebR/);
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
  assert.ok(harness.py.state.configuredScripts.includes('beats'));
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

  // R notebooks stay on the JS path (RunnerCore is Python-only) — no sidecar.
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
    '# Generated from lab.ipynb\n\nx <- 2\n\n',
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
