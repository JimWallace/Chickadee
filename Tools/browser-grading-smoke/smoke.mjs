// Tools/browser-grading-smoke/smoke.mjs
//
// End-to-end smoke probe for browser grading on the vendored xeus kernels
// (#1271) — R via xeus-r, Python via xeus-python.
//
// Everything else that covers these paths proves code *resolves*: the Node suite
// in Tests/BrowserRunnerJSTests runs the cell-building and reply-parsing logic
// against a fake worker, and swift test never leaves the server. None of it
// boots a kernel. This probe does: it serves Public/ over HTTP, loads the real
// grading worker in a real browser, and grades real test scripts.
//
// That matters more here than for most smoke tests, because the failure modes it
// guards against are invisible everywhere else:
//   * the vendored /vendor/xeus-bootstrap.js drifting from what a kernel's
//     empack metadata expects (a re-vendor is the likely cause),
//   * an env rebuilt without the shared libraries its kernel dlopen()s,
//   * R: the quit()/commandArgs() masking silently ceasing to be what
//     test_runtime.R resolves — which would turn every R test into a pass,
//   * Python: the grading cell failing to print its payload, which is the only
//     channel back over the Jupyter protocol.
//
// Each language asserts on stderr explicitly. That is not decoration: the R
// implementation shipped a bug where stderr was silently dropped and every unit
// test still passed, because only a real kernel exposes it.
//
// Usage:  node Tools/browser-grading-smoke/smoke.mjs [--language r|python] [--browser chromium|webkit]
// Exits 0 on success, 1 on any assertion failure or timeout.

import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const REPO_ROOT = path.resolve(import.meta.dirname, '..', '..');
const PUBLIC_DIR = path.join(REPO_ROOT, 'Public');
const PORT = Number(process.env.R_SMOKE_PORT || 8131);
const BOOT_TIMEOUT_MS = Number(process.env.R_SMOKE_TIMEOUT_MS || 300000);

const CONTENT_TYPES = {
    '.js': 'text/javascript',
    '.mjs': 'text/javascript',
    '.wasm': 'application/wasm',
    '.json': 'application/json',
    '.html': 'text/html; charset=utf-8',
    '.gz': 'application/gzip',
    '.so': 'application/wasm',
};

// The kernel is served cross-origin isolated, matching COEPMiddleware on the
// notebook page that hosts the grader. The R substrate does not need
// SharedArrayBuffer (it has no stdin to transport), but grading must be proven
// to work in the isolation mode it actually ships under.
const ISOLATION_HEADERS = {
    'cross-origin-opener-policy': 'same-origin',
    'cross-origin-embedder-policy': 'require-corp',
    'cross-origin-resource-policy': 'cross-origin',
};

// A miniature test setup per language: the helper library the runner injects,
// plus scripts covering every exit path RunnerCore maps to a status.
const TEST_RUNTIME_R = await fs.readFile(
    path.join(REPO_ROOT, 'Tools', 'runner-support', 'test_runtime.R'), 'utf8');
const TEST_RUNTIME_PY = await fs.readFile(
    path.join(REPO_ROOT, 'Tools', 'runner-support', 'test_runtime.py'), 'utf8');
const SITECUSTOMIZE_PY = await fs.readFile(
    path.join(REPO_ROOT, 'Tools', 'runner-support', 'sitecustomize.py'), 'utf8');

const LANGUAGES = {
    r: {
        worker: '/r-grading-worker.js',
        scripts: [
            'publictest_pass.R', 'publictest_fail.R', 'publictest_boom.R',
            'publictest_context.R', 'publictest_packages.R',
        ],
        files: {
            'test_runtime.R': TEST_RUNTIME_R,
            // Exit 0, and a JSON footer RunnerCore reads for the shortResult.
            'publictest_pass.R': `source("test_runtime.R")
cat("checking arithmetic\\n")
if (7 * 191 == 1337) passed("all cases passed") else failed("arithmetic is broken")
`,
            // Exit 1, with the failure message on stdout.
            'publictest_fail.R': `source("test_runtime.R")
failed("expected 5, got 4")
`,
            // Exit 1 from an uncaught R error, not from the helper API.
            'publictest_boom.R': `source("test_runtime.R")
stop("this test blew up")
`,
            // Every package environment-r.yml DECLARES must actually attach in a
            // real kernel. check-env-vendored-sync.sh proves they are in the
            // tarballs; only this proves they LOAD — and an env can be perfectly
            // well-formed and still not work, which is exactly how the Python
            // side shipped a urllib3 that stopped the kernel booting.
            'publictest_packages.R': `source("test_runtime.R")
for (pkg in c("dplyr", "tidyr", "readr", "stringr", "tibble",
              "purrr", "forcats")) {
  t0 <- Sys.time()
  suppressPackageStartupMessages(library(pkg, character.only = TRUE))
  cat(pkg, "=", round(as.numeric(Sys.time() - t0, units = "secs"), 2), "s\\n")
}
passed("all declared packages attached")
`,
            // The label exists only because the wrapper masks commandArgs();
            // the seed comes from the environment and the input from _ck_inputs.
            'publictest_context.R': `source("test_runtime.R")
cat("label=", .chickadee_label(), " seed=", chickadee_seed(), "\\n", sep = "")
cat("input=", chickadee_inputs()[["threshold"]], "\\n", sep = "")
passed("context ok")
`,
            '_ck_inputs.R': '.ck_inputs <- list(\n    `threshold` = 42\n)\n',
            '.chickadee_student_module': 'submission.R',
            'submission.R': 'classify <- function(x) if (x > 0) "positive" else "non-positive"\n',
        },
        expectLabel: /label=publictest_context\b/,
        blewUp: /this test blew up/,
    },
    python: {
        worker: '/python-grading-worker.js',
        scripts: ['publictest_pass.py', 'publictest_fail.py', 'publictest_boom.py', 'publictest_context.py'],
        files: {
            'test_runtime.py': TEST_RUNTIME_PY,
            'sitecustomize.py': SITECUSTOMIZE_PY,
            'publictest_pass.py': `from test_runtime import passed
print("checking arithmetic")
assert 7 * 191 == 1337
passed("all cases passed")
`,
            'publictest_fail.py': `from test_runtime import failed
failed("expected 5, got 4")
`,
            // An uncaught exception, not the helper API: a `python3 script`
            // subprocess exits non-zero with the traceback on stderr.
            'publictest_boom.py': `raise ValueError("this test blew up")
`,
            'publictest_context.py': `import os
from test_runtime import passed
import _ck_inputs
print("label=publictest_context")
print("seed=" + os.environ.get("CHICKADEE_ASSIGNMENT_SEED", ""))
print("input=" + str(_ck_inputs._ck["threshold"]))
passed("context ok")
`,
            '_ck_inputs.py': '_ck = {\n    "threshold": 42,\n}\n',
            '.chickadee_student_module': 'submission.py',
            'submission.py': 'def classify(x):\n    return "positive" if x > 0 else "non-positive"\n',
        },
        expectLabel: /label=publictest_context\b/,
        blewUp: /this test blew up/,
    },
};

const language = (() => {
    const index = process.argv.indexOf('--language');
    const value = index >= 0 ? process.argv[index + 1] : 'r';
    if (!LANGUAGES[value]) {
        console.log(`unknown --language ${value}; expected one of ${Object.keys(LANGUAGES).join(', ')}`);
        process.exit(1);
    }
    return value;
})();
const LANG = LANGUAGES[language];
const FILES = LANG.files;

// `grading` drives the grading worker; `eval` drives the pattern-family
// editor's auto-compute worker (#1271 plan §A2), which speaks a different
// protocol against the same kernel. Both are here rather than in a second tool
// because everything expensive — the static server, the browser launch, the
// generous boot timeout — is shared, and the auto-compute worker needs exactly
// the same thing proving: that a REAL kernel does what the unit tests assume.
const mode = (() => {
    const index = process.argv.indexOf('--mode');
    const value = index >= 0 ? process.argv[index + 1] : 'grading';
    if (value !== 'grading' && value !== 'eval') {
        console.log(`unknown --mode ${value}; expected grading or eval`);
        process.exit(1);
    }
    return value;
})();

const PROBE_PAGE = `<!doctype html><meta charset="utf-8"><title>browser grading smoke</title>
<body><pre id="log"></pre><script>
window.__result = null;
const files = ${JSON.stringify(FILES)};
const scripts = ${JSON.stringify(LANG.scripts)};
(async () => {
  const worker = new Worker('${LANG.worker}');
  let counter = 0;
  const pending = new Map();
  const phases = [];
  worker.onmessage = (event) => {
    const message = event.data || {};
    if (message.type === 'phase') { phases.push(message.phase); return; }
    const settle = pending.get(message.id);
    if (settle) { pending.delete(message.id); settle(message); }
  };
  worker.onerror = (event) => {
    window.__result = { ok: false, stage: 'worker', error: event.message || 'worker error' };
  };
  const call = (payload) => new Promise((resolve) => {
    const id = ++counter;
    pending.set(id, resolve);
    worker.postMessage(Object.assign({ id }, payload));
  });

  const bootStart = Date.now();
  const init = await call({ type: 'init', files, seed: 'deadbeefcafe0123' });
  const bootMs = Date.now() - bootStart;
  if (!init.ok) { window.__result = { ok: false, stage: 'init', error: init.error }; return; }

  const results = {};
  for (const script of scripts) {
    const started = Date.now();
    const reply = await call({ type: 'run', script, limit: 30 });
    if (!reply.ok) { window.__result = { ok: false, stage: script, error: reply.error }; return; }
    results[script] = Object.assign({ ms: Date.now() - started }, reply.result);
  }
  window.__result = { ok: true, bootMs, phases, results };
})().catch((err) => { window.__result = { ok: false, stage: 'page', error: String(err) }; });
</script>`;

// The auto-compute probe. Two solution cells (one of which raises, because a
// failing early cell must NOT stop later cells from defining their functions),
// then expressions evaluated against the namespace they left behind.
const EVAL_PROBE_PAGE = `<!doctype html><meta charset="utf-8"><title>auto-compute smoke</title>
<body><pre id="log"></pre><script>
window.__result = null;
(async () => {
  const worker = new Worker('/python-eval-worker.js');
  let counter = 0;
  const pending = new Map();
  worker.onmessage = (event) => {
    const message = event.data || {};
    const settle = pending.get(message.id);
    if (settle) { pending.delete(message.id); settle(message); }
  };
  worker.onerror = (event) => {
    window.__result = { ok: false, stage: 'worker', error: event.message || 'worker error' };
  };
  const call = (payload) => new Promise((resolve) => {
    const id = ++counter;
    pending.set(id, resolve);
    worker.postMessage(Object.assign({ id }, payload));
  });

  const bootStart = Date.now();
  const init = await call({ type: 'init' });
  const bootMs = Date.now() - bootStart;
  if (!init.ok) { window.__result = { ok: false, stage: 'init', error: init.error }; return; }

  const load = await call({ type: 'loadCells', cells: [
    'import math\\n\\ndef classify(bmi):\\n    return "under" if bmi < 18.5 else "ok"',
    'this_name_does_not_exist()',
    'def area(r):\\n    return round(math.pi * r * r, 2)',
  ] });
  if (!load.ok) { window.__result = { ok: false, stage: 'loadCells', error: load.error }; return; }

  const runs = {};
  for (const [key, code] of Object.entries({
    call: 'classify(18.49)',
    later: 'area(2)',
    statement: 'unused = 1',
    raises: 'classify()',
    // Every package the environment file DECLARES must actually import in a
    // real kernel. check-env-vendored-sync.sh proves they are in the tarballs;
    // only this proves they load. scikit-learn's arrival is what dragged in
    // urllib3, whose emscripten module crashed the kernel on import until
    // patch-xeus-python-http.py was extended — an env can be perfectly
    // well-formed and still not boot.
    declared: 'import numpy, pandas, matplotlib, PIL, scipy, sympy, sklearn, statsmodels\\n'
      + '\"all declared packages imported\"',
  })) {
    const reply = await call({ type: 'run', code });
    runs[key] = reply.ok ? { ok: true, result: reply.result } : { ok: false, error: reply.error };
  }
  window.__result = { ok: true, bootMs, cellErrors: load.cellErrors, runs };
})().catch((err) => { window.__result = { ok: false, stage: 'page', error: String(err) }; });
</script>`;

function startServer() {
    const server = http.createServer(async (req, res) => {
        const urlPath = decodeURIComponent((req.url || '/').split('?')[0]);
        if (urlPath === '/' || urlPath === '/index.html') {
            res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', ...ISOLATION_HEADERS });
            res.end(mode === 'eval' ? EVAL_PROBE_PAGE : PROBE_PAGE);
            return;
        }
        // Confine reads to Public/ — this server exists only to feed the probe.
        const resolved = path.resolve(PUBLIC_DIR, '.' + urlPath);
        if (!resolved.startsWith(PUBLIC_DIR + path.sep)) {
            console.log('[server] refused (outside Public/):', urlPath);
            res.writeHead(403, { 'content-type': 'text/plain; charset=utf-8' });
            res.end('forbidden');
            return;
        }
        try {
            const body = await fs.readFile(resolved);
            res.writeHead(200, {
                'content-type': CONTENT_TYPES[path.extname(resolved)] || 'application/octet-stream',
                ...ISOLATION_HEADERS,
            });
            res.end(body);
        } catch {
            // The requested path is logged rather than echoed into the response:
            // reflecting it would be a (CodeQL-flagged) XSS shape even in a
            // probe-only server, and the console is where a debugging human is
            // looking anyway.
            console.log('[server] 404:', urlPath);
            res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
            res.end('not found');
        }
    });
    return new Promise((resolve) => server.listen(PORT, () => resolve(server)));
}

const failures = [];
function check(label, condition, detail) {
    if (condition) {
        console.log(`  ok   ${label}`);
    } else {
        console.log(`  FAIL ${label}${detail ? ' — ' + detail : ''}`);
        failures.push(label);
    }
}

const browserName = (() => {
    const index = process.argv.indexOf('--browser');
    return index >= 0 ? process.argv[index + 1] : 'chromium';
})();

const server = await startServer();
const playwright = await import('playwright');
const launchOptions = {};
if (browserName === 'chromium' && process.env.PLAYWRIGHT_CHROMIUM_PATH) {
    launchOptions.executablePath = process.env.PLAYWRIGHT_CHROMIUM_PATH;
}
const browser = await playwright[browserName].launch(launchOptions);
let result;
try {
    const page = await browser.newPage();
    page.on('pageerror', (err) => console.log('[pageerror]', err.message));
    await page.goto(`http://localhost:${PORT}/`);
    // waitForFunction is (pageFunction, arg, options) — passing the options as
    // the SECOND argument silently makes them the `arg` and leaves Playwright's
    // 30s default in force. That default is close enough to a cold kernel boot
    // plus four graded scripts that it would have started failing on a slow CI
    // runner, reported as an opaque timeout rather than as anything about R.
    await page.waitForFunction('window.__result !== null', null, { timeout: BOOT_TIMEOUT_MS });
    result = await page.evaluate('window.__result');
} finally {
    await browser.close();
    server.close();
}

console.log(`\nbrowser ${mode} smoke — ${language} (${browserName})`);
if (!result || !result.ok) {
    console.log(`  FAIL boot — stage=${result?.stage} error=${result?.error}`);
    process.exit(1);
}
console.log(`  kernel booted in ${result.bootMs}ms`);

if (mode === 'eval') {
    // A cell that raises must be REPORTED, not swallowed and not fatal: the
    // editor explains a downstream "function not defined" in terms of the
    // earlier cell that crashed, which it can only do if it was told.
    const errors = result.cellErrors || [];
    check('the failing solution cell is reported', errors.length === 1, JSON.stringify(errors));
    check('it is attributed to the right cell', errors[0]?.index === 1, JSON.stringify(errors));
    check('its message is the exception line',
        /NameError/.test(errors[0]?.message || ''), JSON.stringify(errors));

    // The last-expression split. This is the one genuinely new mechanism in the
    // move off Pyodide — runPythonAsync RETURNED this value — and getting it
    // wrong does not throw, it silently yields nothing.
    check('a call expression returns its value',
        result.runs.call?.result === 'under', JSON.stringify(result.runs.call));
    // Proves the namespace survived the cell that raised, which is the whole
    // reason per-cell errors are caught rather than propagated.
    check('a function defined after the failing cell is callable',
        result.runs.later?.result === '12.57', JSON.stringify(result.runs.later));
    check('source ending in a statement runs and yields no value',
        result.runs.statement?.ok === true && result.runs.statement.result === null,
        JSON.stringify(result.runs.statement));
    check('a raising expression is an error, not a null result',
        result.runs.raises?.ok === false && /TypeError|argument/.test(result.runs.raises.error || ''),
        JSON.stringify(result.runs.raises));
    check('every package the environment declares actually imports',
        result.runs.declared?.result === 'all declared packages imported',
        JSON.stringify(result.runs.declared));

    if (failures.length) {
        console.log(`\nFAILED: ${failures.length} check(s)`);
        process.exit(1);
    }
    console.log('\nPASS');
    process.exit(0);
}

console.log(`  phases=${result.phases.join(',')}`);

const [passName, failName, boomName, contextName] = LANG.scripts;
const pass = result.results[passName];
check('a passing test exits 0', pass.exitCode === 0, `exitCode=${pass.exitCode}`);
check('its stdout reaches the grader', /checking arithmetic/.test(pass.stdout), JSON.stringify(pass.stdout));
check('the JSON footer is the last stdout line',
    /"status":\s*"pass"/.test(pass.stdout.trim().split('\n').pop() || ''), JSON.stringify(pass.stdout));

const fail = result.results[failName];
check('a failing test exits 1', fail.exitCode === 1, `exitCode=${fail.exitCode}`);
check('the failure message survives', /expected 5, got 4/.test(fail.stdout + fail.stderr),
    JSON.stringify(fail.stdout));

const boom = result.results[boomName];
check('an uncaught error exits non-zero', boom.exitCode !== 0, `exitCode=${boom.exitCode}`);
// The check that would have caught the R stderr bug. Unit tests cannot see this.
check('its message lands on stderr, for longResult',
    LANG.blewUp.test(boom.stderr), JSON.stringify(boom.stderr));

const context = result.results[contextName];
check('the script label is resolved', LANG.expectLabel.test(context.stdout), JSON.stringify(context.stdout));
check('the per-student seed reaches the runtime',
    /seed=\S/.test(context.stdout) && !/seed=0\b/.test(context.stdout), JSON.stringify(context.stdout));
check('the per-student inputs file is readable',
    /input=42/.test(context.stdout), JSON.stringify(context.stdout));

// Cross-script isolation: each script must be graded as the native runner would,
// in a workspace not polluted by the previous one.
check('every script produced a result',
    [pass, fail, boom, context].every(r => r && typeof r.exitCode === 'number'),
    'a script returned no result');

// R only: the declared-package fixture. Python's equivalent lives in the eval
// probe, which has a namespace to evaluate an import expression against.
if (language === 'r') {
    const packages = result.results['publictest_packages.R'];
    check('every package the environment declares actually attaches',
        packages && packages.exitCode === 0,
        JSON.stringify(packages));
    console.log('  attach timings:', (packages?.stdout || '').replace(/\n/g, ' ').trim());
}

const slowest = Math.max(...Object.values(result.results).map(r => r.ms));
console.log(`  slowest script: ${slowest}ms`);

if (failures.length) {
    console.log(`\nFAILED: ${failures.length} check(s)`);
    process.exit(1);
}
console.log('\nPASS');
