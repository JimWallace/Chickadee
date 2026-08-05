// Tools/r-grading-smoke/smoke.mjs
//
// End-to-end smoke probe for browser-graded R (#1271).
//
// Everything else that covers the R grading path proves code *resolves*: the
// Node suite in Tests/BrowserRunnerJSTests runs the wrapper-building and
// reply-parsing logic against a fake worker, and swift test never leaves the
// server. None of it boots a kernel. This probe does: it serves Public/ over
// HTTP, loads the real Public/r-grading-worker.js in a real browser, and grades
// real R scripts through the vendored xeus-r kernel.
//
// That matters more here than for most smoke tests, because the failure modes
// this guards against are invisible everywhere else:
//   * the vendored /vendor/xeus-bootstrap.js drifting from what the kernel's
//     empack metadata expects (a re-vendor is the likely cause),
//   * Public/jupyterlite/xeus/chickadee-r/ being rebuilt without the shared
//     libraries the kernel dlopen()s,
//   * the wrapper's quit()/commandArgs() masking silently ceasing to be what
//     test_runtime.R resolves — which would turn every R test into a pass.
//
// Usage:  node Tools/r-grading-smoke/smoke.mjs [--browser chromium|webkit]
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

// A miniature test setup: the helper library the runner injects, plus four
// scripts covering every exit path RunnerCore maps to a status.
const TEST_RUNTIME_R = await fs.readFile(
    path.join(REPO_ROOT, 'Tools', 'runner-support', 'test_runtime.R'), 'utf8');

const FILES = {
    'test_runtime.R': TEST_RUNTIME_R,
    // Exit 0, and a JSON footer RunnerCore reads for the shortResult.
    'publictest_pass.R': `source("test_runtime.R")
cat("checking arithmetic\\n")
if (7 * 191 == 1337) passed("all cases passed") else failed("arithmetic is broken")
`,
    // Exit 1, with the failure message on stdout and stderr.
    'publictest_fail.R': `source("test_runtime.R")
failed("expected 5, got 4")
`,
    // Exit 1 from an uncaught R error, not from the helper API.
    'publictest_boom.R': `source("test_runtime.R")
stop("this test blew up")
`,
    // The label comes from commandArgs()'s --file= entry, which only exists
    // because the wrapper masks it; the seed comes from the environment.
    'publictest_context.R': `source("test_runtime.R")
cat("label=", .chickadee_label(), " seed=", chickadee_seed(), "\\n", sep = "")
cat("input=", chickadee_inputs()[["threshold"]], "\\n", sep = "")
passed("context ok")
`,
    '_ck_inputs.R': `.ck_inputs <- list(\n    \`threshold\` = 42\n)\n`,
    '.chickadee_student_module': 'submission.R',
    'submission.R': 'classify <- function(x) if (x > 0) "positive" else "non-positive"\n',
};

const PROBE_PAGE = `<!doctype html><meta charset="utf-8"><title>R grading smoke</title>
<body><pre id="log"></pre><script>
window.__result = null;
const files = ${JSON.stringify(FILES)};
const scripts = ['publictest_pass.R', 'publictest_fail.R', 'publictest_boom.R', 'publictest_context.R'];
(async () => {
  const worker = new Worker('/r-grading-worker.js');
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

function startServer() {
    const server = http.createServer(async (req, res) => {
        const urlPath = decodeURIComponent((req.url || '/').split('?')[0]);
        if (urlPath === '/' || urlPath === '/index.html') {
            res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', ...ISOLATION_HEADERS });
            res.end(PROBE_PAGE);
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
    await page.waitForFunction('window.__result !== null', { timeout: BOOT_TIMEOUT_MS });
    result = await page.evaluate('window.__result');
} finally {
    await browser.close();
    server.close();
}

console.log(`\nR grading smoke (${browserName})`);
if (!result || !result.ok) {
    console.log(`  FAIL boot — stage=${result?.stage} error=${result?.error}`);
    process.exit(1);
}
console.log(`  kernel booted in ${result.bootMs}ms; phases=${result.phases.join(',')}`);

const pass = result.results['publictest_pass.R'];
check('a passing test exits 0', pass.exitCode === 0, `exitCode=${pass.exitCode}`);
check('its stdout reaches the grader', /checking arithmetic/.test(pass.stdout), JSON.stringify(pass.stdout));
check('the JSON footer is the last stdout line',
    /"status":"pass"/.test(pass.stdout.trim().split('\n').pop() || ''), JSON.stringify(pass.stdout));

const fail = result.results['publictest_fail.R'];
check('a failing test exits 1', fail.exitCode === 1, `exitCode=${fail.exitCode}`);
check('the failure message survives', /expected 5, got 4/.test(fail.stdout), JSON.stringify(fail.stdout));

const boom = result.results['publictest_boom.R'];
check('an uncaught R error exits 1', boom.exitCode === 1, `exitCode=${boom.exitCode}`);
check('its message lands on stderr, for longResult',
    /this test blew up/.test(boom.stderr), JSON.stringify(boom.stderr));

const context = result.results['publictest_context.R'];
check('commandArgs masking gives the script label',
    /label=publictest_context\b/.test(context.stdout), JSON.stringify(context.stdout));
check('the per-student seed reaches chickadee_seed()',
    /seed=\d+/.test(context.stdout) && !/seed=0\b/.test(context.stdout), JSON.stringify(context.stdout));
check('_ck_inputs.R reaches chickadee_inputs()',
    /input=42/.test(context.stdout), JSON.stringify(context.stdout));

// Cross-script isolation: the global-environment wipe stands in for the fresh
// process the native runner gets per test. If it regressed, `passed()` from an
// earlier script would still be bound and later scripts would misbehave.
check('each script is graded in a clean global environment',
    pass.exitCode === 0 && context.exitCode === 0,
    `pass=${pass.exitCode} context=${context.exitCode}`);

const slowest = Math.max(...Object.values(result.results).map(r => r.ms));
console.log(`  slowest script: ${slowest}ms`);

if (failures.length) {
    console.log(`\nFAILED: ${failures.length} check(s)`);
    process.exit(1);
}
console.log('\nPASS');
