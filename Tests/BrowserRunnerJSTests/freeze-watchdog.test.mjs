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
