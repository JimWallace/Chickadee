// Tests/BrowserRunnerJSTests/freeze-watchdog.test.mjs
//
// Guards for Public/freeze-watchdog-worker.js — the dedicated worker that
// beacons a `page_unresponsive` diagnostic when the notebook editor page's main
// thread hard-freezes (a synchronous Pyodide hang with no SharedArrayBuffer /
// service-worker sync path). The worker keeps running on its own thread while
// the page is frozen, which is the whole point: the blocked main thread can't
// report itself.
//
// The source uses worker globals (self, setInterval, fetch), so it is loaded in
// a vm context with those stubbed — the same approach as watchdog-probe.test.mjs.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import url from 'node:url';
import vm from 'node:vm';

const here = path.dirname(url.fileURLToPath(import.meta.url));
const workerSource = await fs.readFile(
    path.join(here, '..', '..', 'Public', 'freeze-watchdog-worker.js'),
    'utf8'
);

function loadWorker() {
    let intervalFn = null;
    const fetchCalls = [];
    const state = { nowMs: 1_000_000 };
    const ctx = {
        self: {},
        setInterval: (fn) => { intervalFn = fn; return 1; },
        clearInterval: () => {},
        Date: { now: () => state.nowMs },
        fetch: (u, opts) => { fetchCalls.push({ url: u, opts }); return Promise.resolve(); },
        module: { exports: {} },
        JSON,
    };
    vm.createContext(ctx);
    vm.runInContext(workerSource, ctx);
    return {
        send: (msg) => ctx.self.onmessage({ data: msg }),
        tick: () => { if (intervalFn) intervalFn(); },
        advance: (ms) => { state.nowMs += ms; },
        fetchCalls,
        evaluateStall: ctx.module.exports.evaluateStall,
        evaluateGradingFailover: ctx.module.exports.evaluateGradingFailover,
    };
}

test('evaluateStall: reports only when visible, past threshold, and not already reported', () => {
    const { evaluateStall } = loadWorker();
    const base = { lastBeatMs: 0, thresholdMs: 8000, visible: true, reportedForThisStall: false };
    assert.equal(evaluateStall(base, 9000).shouldReport, true);
    assert.equal(evaluateStall({ ...base, visible: false }, 9000).shouldReport, false);
    assert.equal(evaluateStall({ ...base, reportedForThisStall: true }, 9000).shouldReport, false);
    assert.equal(evaluateStall(base, 5000).shouldReport, false);
});

test('worker beacons page_unresponsive once on a stall, then re-arms after a heartbeat', () => {
    const w = loadWorker();
    w.send({ type: 'init', beaconUrl: '/api/v1/client-diagnostics', setupID: 'setup_x', csrfToken: 't', thresholdMs: 8000 });

    // A normal gap under the threshold does not beacon.
    w.advance(2000);
    w.tick();
    assert.equal(w.fetchCalls.length, 0);

    // Past the threshold → exactly one beacon, even if checked repeatedly.
    w.advance(9000);
    w.tick();
    w.tick();
    assert.equal(w.fetchCalls.length, 1);
    const call = w.fetchCalls[0];
    assert.equal(call.url, '/api/v1/client-diagnostics');
    assert.equal(call.opts.method, 'POST');
    assert.equal(call.opts.headers['x-csrf-token'], 't');
    const body = JSON.parse(call.opts.body);
    assert.equal(body.kind, 'page_unresponsive');
    assert.equal(body.testSetupID, 'setup_x');
    assert.match(body.message, /stalled_ms=\d+/);

    // Recovery heartbeat re-arms; a later stall beacons again.
    w.send({ type: 'beat' });
    w.advance(9000);
    w.tick();
    assert.equal(w.fetchCalls.length, 2);
});

test('worker does not beacon while the tab is hidden', () => {
    const w = loadWorker();
    w.send({ type: 'init', beaconUrl: '/u', setupID: 's', csrfToken: '', thresholdMs: 8000 });
    w.send({ type: 'visibility', visible: false });
    w.advance(20000);
    w.tick();
    assert.equal(w.fetchCalls.length, 0);
});

// --- Grading failover -------------------------------------------------------

test('evaluateGradingFailover: only armed, visible, past threshold, not yet fired', () => {
    const { evaluateGradingFailover } = loadWorker();
    const base = {
        lastBeatMs: 0, gradingThresholdMs: 30000,
        visible: true, gradingArmed: true, gradingFailedOver: false,
    };
    assert.equal(evaluateGradingFailover(base, 31000).shouldFailover, true);
    assert.equal(evaluateGradingFailover({ ...base, gradingArmed: false }, 31000).shouldFailover, false);
    assert.equal(evaluateGradingFailover({ ...base, gradingFailedOver: true }, 31000).shouldFailover, false);
    assert.equal(evaluateGradingFailover({ ...base, visible: false }, 31000).shouldFailover, false);
    assert.equal(evaluateGradingFailover(base, 5000).shouldFailover, false);
});

test('armed grade that freezes posts exactly one failover with the stashed notebook', () => {
    const w = loadWorker();
    w.send({ type: 'init', beaconUrl: '/api/v1/client-diagnostics', setupID: 'setup_z', csrfToken: 'init-tok', thresholdMs: 8000 });
    w.send({
        type: 'grading-armed',
        setupID: 'setup_z',
        notebook: '{"cells":[]}',
        failoverUrl: '/api/v1/submissions/browser-failover',
        csrfToken: 'grade-tok',
        thresholdMs: 30000,
    });

    // Healthy window under the grading threshold → no failover (the 8s beacon
    // may fire, but no failover POST).
    w.advance(9000);
    w.tick();
    assert.equal(w.fetchCalls.filter(c => c.url === '/api/v1/submissions/browser-failover').length, 0);

    // Past the grading threshold → exactly one failover POST, even if ticked again.
    w.advance(30000);
    w.tick();
    w.tick();
    const failovers = w.fetchCalls.filter(c => c.url === '/api/v1/submissions/browser-failover');
    assert.equal(failovers.length, 1);
    const call = failovers[0];
    assert.equal(call.opts.method, 'POST');
    assert.equal(call.opts.headers['x-csrf-token'], 'grade-tok');
    const body = JSON.parse(call.opts.body);
    assert.equal(body.testSetupID, 'setup_z');
    assert.equal(body.notebook, '{"cells":[]}');
});

test('disarming before the threshold cancels the failover', () => {
    const w = loadWorker();
    w.send({ type: 'init', beaconUrl: '/u', setupID: 's', csrfToken: '', thresholdMs: 8000 });
    w.send({ type: 'grading-armed', setupID: 's', notebook: '{}', failoverUrl: '/fo', thresholdMs: 30000 });
    // Grade finished fast: disarm, then time passes.
    w.send({ type: 'grading-disarmed' });
    w.advance(60000);
    w.tick();
    assert.equal(w.fetchCalls.filter(c => c.url === '/fo').length, 0);
});

test('a heartbeat-fed (healthy) grade never fails over', () => {
    const w = loadWorker();
    w.send({ type: 'init', beaconUrl: '/u', setupID: 's', csrfToken: '', thresholdMs: 8000 });
    w.send({ type: 'grading-armed', setupID: 's', notebook: '{}', failoverUrl: '/fo', thresholdMs: 30000 });
    // Beats keep arriving (main thread responsive) — stall never reaches 30s.
    for (let i = 0; i < 30; i++) {
        w.advance(2000);
        w.send({ type: 'beat' });
        w.tick();
    }
    assert.equal(w.fetchCalls.filter(c => c.url === '/fo').length, 0);
});
