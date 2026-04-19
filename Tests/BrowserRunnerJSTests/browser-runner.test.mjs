import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const runnerSource = await fs.readFile(
  path.resolve('Public/browser-runner.js'),
  'utf8',
);

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
        shortResult: "Skipped: prerequisite 'test_build.py' did not pass",
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

test('browser runner keeps display names separate from output and extracts traceback-only details', async () => {
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
          test: 'Q1: BMI Calculation',
          error: 'Could not test calculate_bmi',
          exception: "NotImplementedError('Implement calculate_bmi')",
          traceback: 'Traceback (most recent call last):\n  File "test_q1_bmi.py", line 12, in <module>\n    result = fn(*args)\nNotImplementedError: Implement calculate_bmi\n',
        })}\n`,
        stderr: '',
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
      testName: 'test_q1_bmi',
      testClass: null,
      tier: 'public',
      status: 'error',
      shortResult: 'Could not test calculate_bmi',
      longResult: 'Traceback (most recent call last):\n  File "test_q1_bmi.py", line 12, in <module>\n    result = fn(*args)\nNotImplementedError: Implement calculate_bmi',
      executionTimeMs: result.outcomes[0].executionTimeMs,
      memoryUsageBytes: null,
      attemptNumber: 1,
      isFirstPassSuccess: false,
      scriptName: 'test_q1_bmi.py',
      displayName: 'Q1: BMI Calculation',
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

test('extractNotebook writes python and R student module hints correctly', async () => {
  const harness = await loadRunnerHarness();
  const { extractNotebook } = harness.hooks;

  harness.py.FS.mkdir('/course');

  await extractNotebook(
    harness.py,
    '/course',
    'submission.ipynb',
    JSON.stringify({
      nbformat: 4,
      metadata: {
        kernelspec: { name: 'python3' },
      },
      cells: [
        { cell_type: 'markdown', source: ['ignore'], metadata: {} },
        { cell_type: 'code', source: ['x = 1\n'], metadata: {} },
        { cell_type: 'code', source: ['print(x)\n'], metadata: {} },
      ],
    }),
  );

  assert.equal(
    harness.py.FS.readFile('/course/submission.py', { encoding: 'utf8' }),
    '# Generated from submission.ipynb\n\nx = 1\n\nprint(x)\n\n',
  );
  assert.equal(
    harness.py.FS.readFile('/course/.chickadee_student_module', { encoding: 'utf8' }),
    'submission.py',
  );

  await extractNotebook(
    harness.py,
    '/course',
    'lab.ipynb',
    JSON.stringify({
      nbformat: 4,
      metadata: {
        kernelspec: { name: 'webr' },
        language_info: { name: 'r' },
      },
      cells: [
        { cell_type: 'code', source: ['x <- 2\n'], metadata: {} },
      ],
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
