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
// SECOND JOB — grading failover. Browser grading runs Pyodide on the main
// thread, so a synchronous runaway loop in student code freezes the tab and the
// in-browser grade never completes (and never POSTs a result). Before grading
// starts the page ARMS this worker with the notebook bytes + a failover URL;
// when the main thread then stalls past `gradingThresholdMs`, this worker —
// still alive on its own thread — POSTs the notebook to `/browser-failover` so
// the native worker backstop grades it. The page DISARMS on completion. This is
// the one component that can act when the main thread is dead, which is the
// whole reason the failover lives here.
//
// The decisions are factored into `evaluateStall()` / `evaluateGradingFailover()`
// so they can be unit tested (Tests/BrowserRunnerJSTests/freeze-watchdog.test.mjs)
// without a worker.

'use strict';

var beaconUrl = null;
var setupID = null;
var csrfToken = '';
var thresholdMs = 8000;
// Page-build ChickadeeVersion, passed in via `init` (a worker has no DOM to read
// the meta). Stamped on the beacon so a freeze is attributable to a build.
var appVersion = '';
var lastBeatMs = Date.now();
var visible = true;
var reportedForThisStall = false;
var timer = null;

// Grading-failover state (armed by the page before in-browser grading begins).
var gradingArmed = false;
var gradingNotebook = null;
var gradingSetupID = null;
var gradingFailoverUrl = null;
var gradingCsrf = '';
var gradingThresholdMs = 30000;
var gradingFailedOver = false;

// Pure decision: given the current state, should a freeze be reported, and what
// is the next `reported` flag? Kept side-effect-free for testing.
function evaluateStall(state, nowMs) {
    var stalledMs = nowMs - state.lastBeatMs;
    var shouldReport =
        state.visible && stalledMs >= state.thresholdMs && !state.reportedForThisStall;
    return { shouldReport: shouldReport, stalledMs: stalledMs };
}

// Pure decision: while a grade is armed, has the main thread stalled long enough
// that we should give up on the in-browser run and fail over to the server?
// One-shot per arm (the caller latches `gradingFailedOver`). Gated on `visible`
// for the same reason as the freeze beacon: a backgrounded tab throttles the
// page's heartbeat timer, which must not read as a freeze.
function evaluateGradingFailover(state, nowMs) {
    var stalledMs = nowMs - state.lastBeatMs;
    var shouldFailover =
        state.gradingArmed &&
        !state.gradingFailedOver &&
        state.visible &&
        stalledMs >= state.gradingThresholdMs;
    return { shouldFailover: shouldFailover, stalledMs: stalledMs };
}

function check() {
    var nowMs = Date.now();
    if (beaconUrl) {
        var decision = evaluateStall(
            {
                lastBeatMs: lastBeatMs,
                thresholdMs: thresholdMs,
                visible: visible,
                reportedForThisStall: reportedForThisStall,
            },
            nowMs
        );
        if (decision.shouldReport) {
            reportedForThisStall = true;
            beacon(decision.stalledMs);
        }
    }
    var failover = evaluateGradingFailover(
        {
            lastBeatMs: lastBeatMs,
            gradingThresholdMs: gradingThresholdMs,
            visible: visible,
            gradingArmed: gradingArmed,
            gradingFailedOver: gradingFailedOver,
        },
        nowMs
    );
    if (failover.shouldFailover) {
        gradingFailedOver = true;
        postGradingFailover();
    }
}

// POST the stashed notebook to the failover endpoint so the native backstop
// grades it. No `keepalive` (a notebook can exceed its 64 KB cap, and a frozen
// tab stays open — only the main thread is blocked — so the worker's own thread
// completes the fetch). Best-effort and fully guarded.
function postGradingFailover() {
    try {
        if (!gradingFailoverUrl || !gradingSetupID || !gradingNotebook) return;
        fetch(gradingFailoverUrl, {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'content-type': 'application/json', 'x-csrf-token': gradingCsrf },
            body: JSON.stringify({ testSetupID: gradingSetupID, notebook: gradingNotebook }),
        }).catch(function () {
            /* best-effort failover */
        });
        gradingNotebook = null;  // free the bytes; one-shot per arm
    } catch (_) {
        /* never throw in the worker */
    }
}

function beacon(stalledMs) {
    try {
        var body = { kind: 'page_unresponsive', message: 'stalled_ms=' + stalledMs };
        if (setupID) body.testSetupID = setupID;
        if (appVersion) body.appVersion = appVersion;
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
            appVersion = msg.appVersion || '';
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
        case 'grading-armed':
            // The page is about to start an in-browser grade. Stash what we need
            // to fail over if it freezes.
            gradingArmed = true;
            gradingFailedOver = false;
            gradingNotebook = msg.notebook || null;
            gradingSetupID = msg.setupID || setupID;
            gradingFailoverUrl = msg.failoverUrl || '/api/v1/submissions/browser-failover';
            gradingCsrf = msg.csrfToken || csrfToken;
            if (typeof msg.thresholdMs === 'number') gradingThresholdMs = msg.thresholdMs;
            // Measure the stall from the moment grading begins, not from a
            // pre-existing idle gap — otherwise an editor that sat idle would
            // trip the failover the instant a grade starts.
            lastBeatMs = Date.now();
            if (!timer) timer = setInterval(check, 1000);
            break;
        case 'grading-disarmed':
            // Grade finished (passed, failed, or the page handled the failure
            // itself). Disarm and free the stashed bytes.
            gradingArmed = false;
            gradingFailedOver = false;
            gradingNotebook = null;
            break;
        default:
            break;
    }
};

// Test hook: in Node (no `self.onmessage` dispatch loop), expose the pure
// decisions. No-op in a real worker scope.
if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        evaluateStall: evaluateStall,
        evaluateGradingFailover: evaluateGradingFailover,
    };
}
