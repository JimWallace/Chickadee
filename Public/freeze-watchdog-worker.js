// Public/freeze-watchdog-worker.js
//
// Main-thread freeze detector for the student notebook editor page.
//
// notebook.js posts a heartbeat to this worker on a fixed interval. Because the
// worker runs on its OWN thread, it keeps ticking even when the page's main
// thread is hard-blocked — e.g. when the JupyterLite/Pyodide kernel performs a
// synchronous operation with no SharedArrayBuffer (page not cross-origin
// isolated) and no service-worker sync fallback (the SW manager is disabled),
// which manifests as Chrome's "Page Unresponsive". A same-origin iframe shares
// the parent's event loop, so the kernel's hang stops the parent's heartbeats
// too — and this worker notices.
//
// When heartbeats stop for longer than the threshold AND the tab is visible (so
// a throttled background tab isn't mistaken for a freeze), the worker beacons a
// `page_unresponsive` diagnostic to /api/v1/client-diagnostics directly — the
// frozen main thread can't, which is exactly why these freezes were invisible
// in telemetry until now. This is pure, best-effort observability: it never
// touches the editor and never throws into the page.
//
// The freeze decision is factored into `evaluateStall()` so it can be unit
// tested (Tests/BrowserRunnerJSTests/freeze-watchdog.test.mjs) without a worker.

'use strict';

var beaconUrl = null;
var setupID = null;
var csrfToken = '';
var thresholdMs = 8000;
var lastBeatMs = Date.now();
var visible = true;
var reportedForThisStall = false;
var timer = null;

// Pure decision: given the current state, should a freeze be reported, and what
// is the next `reported` flag? Kept side-effect-free for testing.
function evaluateStall(state, nowMs) {
    var stalledMs = nowMs - state.lastBeatMs;
    var shouldReport =
        state.visible && stalledMs >= state.thresholdMs && !state.reportedForThisStall;
    return { shouldReport: shouldReport, stalledMs: stalledMs };
}

function check() {
    if (!beaconUrl) return;
    var decision = evaluateStall(
        {
            lastBeatMs: lastBeatMs,
            thresholdMs: thresholdMs,
            visible: visible,
            reportedForThisStall: reportedForThisStall,
        },
        Date.now()
    );
    if (decision.shouldReport) {
        reportedForThisStall = true;
        beacon(decision.stalledMs);
    }
}

function beacon(stalledMs) {
    try {
        var body = { kind: 'page_unresponsive', message: 'stalled_ms=' + stalledMs };
        if (setupID) body.testSetupID = setupID;
        fetch(beaconUrl, {
            method: 'POST',
            credentials: 'same-origin',
            keepalive: true,
            headers: { 'content-type': 'application/json', 'x-csrf-token': csrfToken },
            body: JSON.stringify(body),
        }).catch(function () {
            /* best-effort telemetry */
        });
    } catch (_) {
        /* never throw in the worker */
    }
}

self.onmessage = function (e) {
    var msg = e.data || {};
    switch (msg.type) {
        case 'init':
            beaconUrl = msg.beaconUrl || null;
            setupID = msg.setupID || null;
            csrfToken = msg.csrfToken || '';
            if (typeof msg.thresholdMs === 'number') thresholdMs = msg.thresholdMs;
            lastBeatMs = Date.now();
            if (!timer) timer = setInterval(check, 1000);
            break;
        case 'beat':
            lastBeatMs = Date.now();
            // A heartbeat after a stall means the page recovered — re-arm so a
            // later freeze reports again (the server also rate-limits duplicates).
            reportedForThisStall = false;
            break;
        case 'visibility':
            visible = !!msg.visible;
            // Becoming visible after a hidden stretch must not read as a freeze:
            // reset the clock so detection starts fresh.
            if (visible) {
                lastBeatMs = Date.now();
                reportedForThisStall = false;
            }
            break;
        default:
            break;
    }
};

// Test hook: in Node (no `self.onmessage` dispatch loop), expose the pure
// decision. No-op in a real worker scope.
if (typeof module !== 'undefined' && module.exports) {
    module.exports = { evaluateStall: evaluateStall };
}
