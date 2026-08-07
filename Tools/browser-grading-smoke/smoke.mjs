// Tools/browser-grading-smoke/smoke.mjs
//
// End-to-end smoke probe for browser grading on the vendored xeus kernels
// (#1271) — R via xeus-r, Python via xeus-python, Lua via xeus-lua.
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
//   * Lua: the os.exit() replacement ceasing to be what test_runtime.lua
//     reaches, which would report every test as a pass — the same failure shape
//     R's quit() masking has, and equally invisible without a kernel.
//
// Each language asserts on stderr explicitly. That is not decoration: the R
// implementation shipped a bug where stderr was silently dropped and every unit
// test still passed, because only a real kernel exposes it.
//
// Usage:  node Tools/browser-grading-smoke/smoke.mjs [--language r|python|lua] [--browser chromium|webkit]
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
const TEST_RUNTIME_LUA = await fs.readFile(
    path.join(REPO_ROOT, 'Tools', 'runner-support', 'test_runtime.lua'), 'utf8');
const TEST_RUNTIME_OCTAVE = await fs.readFile(
    path.join(REPO_ROOT, 'Tools', 'runner-support', 'test_runtime.m'), 'utf8');

const LANGUAGES = {
    r: {
        worker: '/r-grading-worker.js',
        scripts: [
            'publictest_pass.R', 'publictest_fail.R', 'publictest_boom.R',
            'publictest_context.R', 'publictest_nopackage.R', 'publictest_packages.R',
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
            // A package R does not have must fail the ordinary way. This is what
            // shows the on-demand retry terminates instead of spinning, and that
            // a student's typo still reads as a plain "no package called".
            'publictest_nopackage.R': `library(notarealpackage)
`,
            // Every package environment-r.yml DECLARES must actually attach in a
            // real kernel. check-env-vendored-sync.sh proves they are in the
            // tarballs; only this proves they LOAD — and an env can be perfectly
            // well-formed and still not work, which is exactly how the Python
            // side shipped a urllib3 that stopped the kernel booting.
            //
            // Since the kernel now boots with base R only, this also exercises
            // on-demand install seven times over: each library() call misses,
            // installs, and the script re-runs. Attaching an already-attached
            // package is instant, so the retries cost only the new package each
            // time.
            'publictest_packages.R': `source("test_runtime.R")
for (pkg in c("dplyr", "tidyr", "readr", "stringr", "tibble",
              "purrr", "forcats")) {
  t0 <- Sys.time()
  suppressPackageStartupMessages(library(pkg, character.only = TRUE))
  cat(pkg, "=", round(as.numeric(Sys.time() - t0, units = "secs"), 2), "s\\n")
}
# Attaching is not working. Call into several of them so a package that loaded
# but cannot run — or an on-demand install that landed an incomplete closure —
# fails here rather than reporting a green attach.
d <- dplyr::filter(tibble::tibble(x = c(1, 5, 9)), x > 2)
stopifnot(nrow(d) == 2)
stopifnot(stringr::str_to_upper("ok") == "OK")
stopifnot(identical(purrr::map_dbl(1:3, ~ .x * 2), c(2, 4, 6)))
stopifnot(nrow(tidyr::pivot_longer(tibble::tibble(a = 1, b = 2), everything())) == 2)
stopifnot(as.character(forcats::fct_rev(factor(c("a", "b")))[1]) == "a")
stopifnot(readr::parse_number("42 items") == 42)
passed("all declared packages attached and ran")
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
        scripts: [
            'publictest_pass.py', 'publictest_fail.py', 'publictest_boom.py',
            'publictest_context.py', 'publictest_ondemand.py', 'publictest_nomodule.py',
        ],
        files: {
            'test_runtime.py': TEST_RUNTIME_PY,
            'sitecustomize.py': SITECUSTOMIZE_PY,
            // On-demand package loading. The grading kernel boots the bare
            // interpreter (`bootSeeds`), so numpy is genuinely absent when this
            // script starts — it can only pass if the ModuleNotFoundError was
            // caught, numpy's closure installed into the LIVE kernel, and the
            // script re-run. Nothing but a real kernel can prove that.
            'publictest_ondemand.py': `from test_runtime import passed
import numpy
assert int(numpy.arange(4).sum()) == 6
passed("numpy loaded on demand")
`,
            // The other half of the same mechanism: a module the environment
            // does NOT have must fail exactly as it always did. This is what
            // proves the retry loop terminates instead of spinning, and that a
            // student's typo still reads as a plain ImportError.
            'publictest_nomodule.py': `import torch_not_in_this_env
`,
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
    lua: {
        worker: '/lua-grading-worker.js',
        // Order matters from `publictest_leak` on: the isolation fixture below
        // asserts on what the one before it left behind.
        scripts: [
            'publictest_pass.lua', 'publictest_fail.lua', 'publictest_boom.lua',
            'publictest_context.lua', 'publictest_nomodule.lua',
            'publictest_student.lua', 'publictest_leak.lua', 'publictest_isolation.lua',
        ],
        files: {
            'test_runtime.lua': TEST_RUNTIME_LUA,
            // Exit 0, and a JSON footer RunnerCore reads for the shortResult.
            // `require` rather than `dofile` on purpose: the kernel's
            // package.path points only at its own asset dir, so this line is
            // what proves the wrapper restored the cwd-relative search path a
            // `lua script.lua` subprocess has by default.
            'publictest_pass.lua': `local t = require("test_runtime")
print("checking arithmetic")
if 7 * 191 == 1337 then t.passed("all cases passed") else t.failed("arithmetic is broken") end
`,
            // Exit 1, with the failure message on stdout.
            'publictest_fail.lua': `local t = require("test_runtime")
t.failed("expected 5, got 4")
`,
            // Exit 1 from an uncaught Lua error, not from the helper API. Under
            // `lua` this writes the message to stderr and exits 1; the wrapper
            // has to reproduce both, and only a kernel shows whether it did.
            'publictest_boom.lua': `local t = require("test_runtime")
error("this test blew up")
`,
            // The label exists only because the wrapper sets `arg`; the seed
            // comes from the os.getenv overlay and the input from _ck_inputs.
            'publictest_context.lua': `local t = require("test_runtime")
print("label=" .. t.label())
print("seed=" .. t.seed())
print("input=" .. tostring(t.inputs()["threshold"]))
t.passed("context ok")
`,
            // A module Lua does not have must fail the ordinary way. Lua has no
            // package ecosystem on emscripten-forge at all, so this is the ONLY
            // half of the on-demand mechanism it can exercise — which makes it
            // the more important half: it shows the retry loop terminates with
            // nothing to install rather than spinning, and that a student's
            // typo still reads as a plain "module not found".
            'publictest_nomodule.lua': `require("notarealmodule")
`,
            // The grading model this kernel was chosen to test: a test script
            // loading the student's file and calling what it defined.
            'publictest_student.lua': `local t = require("test_runtime")
local env = t.load_student()
local classify = t.require_fn(env, "classify")
if classify(1) ~= "positive" then t.failed("classify(1) should be positive") end
if classify(-1) ~= "non-positive" then t.failed("classify(-1) should be non-positive") end
t.passed("the submission loaded and ran")
`,
            // The native runner gives every test a fresh process. One kernel
            // state serves all of them, so the wrapper emulates that by
            // removing globals added since boot — these two fixtures are the
            // only thing that can show it works.
            'publictest_leak.lua': `local t = require("test_runtime")
leaked_from_a_previous_test = "yes"
t.passed("left a global behind")
`,
            'publictest_isolation.lua': `local t = require("test_runtime")
if rawget(_G, "leaked_from_a_previous_test") ~= nil then
  t.failed("a global from a previous test survived into this one")
end
if type(print) ~= "function" or type(os.getenv) ~= "function" then
  t.failed("the wipe took the standard library with it")
end
t.passed("the workspace is fresh")
`,
            '_ck_inputs.lua': 'return {\n    ["threshold"] = 42,\n}\n',
            '.chickadee_student_module': 'submission.lua',
            'submission.lua':
                'function classify(x)\n'
                + '  if x > 0 then return "positive" else return "non-positive" end\n'
                + 'end\n',
        },
        expectLabel: /label=publictest_context\b/,
        blewUp: /this test blew up/,
    },
    octave: {
        worker: '/octave-grading-worker.js',
        // Order matters from `publictest_leak` on: the isolation fixture below
        // asserts on what the one before it left behind.
        scripts: [
            'publictest_pass.m', 'publictest_fail.m', 'publictest_boom.m',
            'publictest_context.m', 'publictest_nopackage.m',
            'publictest_student.m', 'publictest_leak.m', 'publictest_isolation.m',
        ],
        files: {
            'test_runtime.m': TEST_RUNTIME_OCTAVE,
            // Exit 0, and a JSON footer RunnerCore reads for the shortResult.
            // `chickadee = test_runtime();` resolves through the load path,
            // which is what proves the mounted workspace's cwd is on it.
            'publictest_pass.m': `chickadee = test_runtime();
disp("checking arithmetic")
if 7 * 191 == 1337
  chickadee.passed("all cases passed");
else
  chickadee.failed("arithmetic is broken");
end
`,
            // Exit 1, with the failure message on stdout.
            'publictest_fail.m': `chickadee = test_runtime();
chickadee.failed("expected 5, got 4");
`,
            // Exit 1 from an uncaught Octave error, not the helper API. Under
            // octave-cli this writes \`error: ...\` to stderr and exits 1; the
            // wrapper has to reproduce both, and only a kernel shows whether
            // it did.
            'publictest_boom.m': `chickadee = test_runtime();
error("this test blew up")
`,
            // The label exists only because the wrapper masks program_name();
            // the seed comes via setenv and the input from _ck_inputs.m.
            'publictest_context.m': `chickadee = test_runtime();
printf("label=%s\\n", chickadee.label());
printf("seed=%d\\n", chickadee.seed());
ck_in = chickadee.inputs();
printf("input=%d\\n", ck_in("threshold"));
chickadee.passed("context ok");
`,
            // A package Octave does not have must fail the ordinary way. The
            // channel carries no Octave Forge packages at all, so as with Lua
            // this is the only reachable half of the on-demand mechanism —
            // the half a student's typo actually hits. It proves the retry
            // loop terminates with nothing to install.
            'publictest_nopackage.m': `pkg load notarealpackage
`,
            // The grading model: a test script loading the student's file and
            // calling what it defined.
            'publictest_student.m': `chickadee = test_runtime();
env = chickadee.load_student();
classify = chickadee.require_fn(env, "classify");
if !chickadee.equal(classify(1), "positive")
  chickadee.failed("classify(1) should be positive");
end
if !chickadee.equal(classify(-1), "non-positive")
  chickadee.failed("classify(-1) should be non-positive");
end
chickadee.passed("the submission loaded and ran");
`,
            // The native runner gives every test a fresh process. One kernel
            // session serves all of them; ordinary variables die with the
            // harness call's own workspace, and globals — the one thing that
            // outlives it — are cleared per script. These two fixtures are
            // the only thing that can show both halves work.
            'publictest_leak.m': `chickadee = test_runtime();
leaked_plain = "yes";
global leaked_global;
leaked_global = "yes";
chickadee.passed("left a variable and a global behind");
`,
            'publictest_isolation.m': `chickadee = test_runtime();
if exist("leaked_plain", "var")
  chickadee.failed("a plain variable from a previous test survived into this one");
end
global leaked_global;
if !isempty(leaked_global)
  chickadee.failed("a global from a previous test survived into this one");
end
if !strcmp(getenv("CK_SMOKE_CANARY"), "")
  chickadee.failed("unexpected canary env");
end
chickadee.passed("the workspace is fresh");
`,
            '_ck_inputs.m': '% Auto-generated per-student grading inputs (issue #461). Do not edit.\n'
                + 'ck_input_names = { "threshold" };\nck_input_values = { 42 };\n',
            '.chickadee_student_module': 'submission.m',
            'submission.m':
                'function r = classify(x)\n'
                + '  if x > 0\n'
                + '    r = "positive";\n'
                + '  else\n'
                + '    r = "non-positive";\n'
                + '  end\n'
                + 'end\n',
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
    declared: 'import numpy, pandas, matplotlib, PIL, scipy, statsmodels\\n'
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
// Python only: on-demand package loading. The kernel boots without numpy, so a
// pass here means the missing-module path actually installed it mid-suite; and
// a module the env lacks must still fail the ordinary way, which is what shows
// the retry terminates rather than spinning.
if (language === 'python') {
    const onDemand = result.results['publictest_ondemand.py'];
    check('a package absent at boot is installed on demand',
        onDemand && onDemand.exitCode === 0, JSON.stringify(onDemand));
    check('the on-demand package actually computes',
        /numpy loaded on demand/.test((onDemand?.stdout || '') + (onDemand?.stderr || '')),
        JSON.stringify(onDemand?.stdout));

    const noModule = result.results['publictest_nomodule.py'];
    check('a module the environment lacks still fails normally',
        noModule && noModule.exitCode !== 0, JSON.stringify(noModule));
    check('and says so, rather than looping or going silent',
        /torch_not_in_this_env/.test((noModule?.stderr || '') + (noModule?.stdout || '')),
        JSON.stringify(noModule?.stderr));
}

if (language === 'r') {
    // Doubles as the on-demand test: the kernel boots with base R only, so each
    // of these seven attaches misses, installs, and re-runs the script.
    const packages = result.results['publictest_packages.R'];
    check('every declared package attaches, installing each on demand',
        packages && packages.exitCode === 0,
        JSON.stringify(packages));
    console.log('  attach timings:', (packages?.stdout || '').replace(/\n/g, ' ').trim());

    const noPackage = result.results['publictest_nopackage.R'];
    check('a package the environment lacks still fails normally',
        noPackage && noPackage.exitCode !== 0, JSON.stringify(noPackage));
    check('and says so, rather than looping or going silent',
        /notarealpackage/.test((noPackage?.stderr || '') + (noPackage?.stdout || '')),
        JSON.stringify(noPackage?.stderr));
}

if (language === 'lua') {
    // The seed is the one number that must come out the same in every
    // substrate, or a student's personalized inputs differ between the browser
    // grade and the worker re-grade of the same submission. Lua's fold is the
    // same Horner reduction R uses, so the expected value is checkable by hand
    // and is asserted exactly rather than merely for being non-zero:
    //   python3 -c "a=0
    //   for c in 'deadbeefcafe0123': a=(a*16+int(c,16))%2147483647
    //   print(a)"
    check('the seed is the value the shared Horner fold produces',
        /seed=140082950\b/.test(context.stdout), JSON.stringify(context.stdout));

    // Lua has no packages on emscripten-forge, so the only reachable half of
    // the on-demand mechanism is the terminating one — which is also the half
    // a student's typo hits.
    const noModule = result.results['publictest_nomodule.lua'];
    check('a module the environment lacks still fails normally',
        noModule && noModule.exitCode !== 0, JSON.stringify(noModule));
    check('and says so, rather than looping or going silent',
        /notarealmodule/.test((noModule?.stderr || '') + (noModule?.stdout || '')),
        JSON.stringify(noModule?.stderr));

    // The grading model xeus-lua was picked to test: a test script loading the
    // student's file and calling into it.
    const student = result.results['publictest_student.lua'];
    check('a test can load the submission and call what it defines',
        student && student.exitCode === 0, JSON.stringify(student));

    // Each native test gets a fresh process; one kernel state serves all of
    // these, so the wrapper has to emulate that and nothing but a kernel can
    // show whether it does.
    const leak = result.results['publictest_leak.lua'];
    const isolation = result.results['publictest_isolation.lua'];
    check('the fixture that leaks a global passes',
        leak && leak.exitCode === 0, JSON.stringify(leak));
    check('the next script does not see it, and still has its standard library',
        isolation && isolation.exitCode === 0, JSON.stringify(isolation));
}

if (language === 'octave') {
    // The seed is the one number that must come out the same in every
    // substrate. Octave's fold is the same Horner reduction R and Lua use, so
    // the expected value is checkable by hand and asserted exactly:
    //   python3 -c "a=0
    //   for c in 'deadbeefcafe0123': a=(a*16+int(c,16))%2147483647
    //   print(a)"
    check('the seed is the value the shared Horner fold produces',
        /seed=140082950\b/.test(context.stdout), JSON.stringify(context.stdout));

    // No Octave Forge packages exist on the channel, so the only reachable
    // half of the on-demand mechanism is the terminating one — which is also
    // the half a student's typo hits.
    const noPackage = result.results['publictest_nopackage.m'];
    check('a package the environment lacks still fails normally',
        noPackage && noPackage.exitCode !== 0, JSON.stringify(noPackage));
    check('and says so, rather than looping or going silent',
        /notarealpackage/.test((noPackage?.stderr || '') + (noPackage?.stdout || '')),
        JSON.stringify(noPackage?.stderr));

    // The grading model: a test script loading the submission (behind the
    // 1;-guard eval, so its function registers under its own name) and
    // calling into it.
    const student = result.results['publictest_student.m'];
    check('a test can load the submission and call what it defines',
        student && student.exitCode === 0, JSON.stringify(student));

    // Each native test gets a fresh process; one kernel session serves all of
    // these, so the wrapper has to emulate that and nothing but a kernel can
    // show whether it does — for plain variables (the harness call's own
    // workspace) and globals (cleared per script) alike.
    const leakOct = result.results['publictest_leak.m'];
    const isolationOct = result.results['publictest_isolation.m'];
    check('the fixture that leaks a variable and a global passes',
        leakOct && leakOct.exitCode === 0, JSON.stringify(leakOct));
    check('the next script sees neither',
        isolationOct && isolationOct.exitCode === 0, JSON.stringify(isolationOct));
}

const slowest = Math.max(...Object.values(result.results).map(r => r.ms));
console.log(`  slowest script: ${slowest}ms`);

if (failures.length) {
    console.log(`\nFAILED: ${failures.length} check(s)`);
    process.exit(1);
}
console.log('\nPASS');
