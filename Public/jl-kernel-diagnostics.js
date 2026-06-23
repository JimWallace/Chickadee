// Public/jl-kernel-diagnostics.js
//
// Passive kernel-boot diagnostics, injected into the JupyterLite editor
// documents (notebooks/repl index.html) so it runs INSIDE the editor iframe —
// the same context as the Pyodide kernel, where the boot actually happens and
// where errors are visible. The parent notebook page cannot read across the
// cross-process iframe boundary (the Safari/iPad problem), which is exactly why
// kernel hangs were invisible: a hung kernel still left the parent reporting a
// green `editor_ready`. From the inside we can see the truth.
//
// It is a PURE OBSERVER: fully try/catch-guarded, fire-and-forget, never touches
// the kernel or the page. It `postMessage`s two things to the parent window,
// which forwards them through the normal client-diagnostics pipeline (the parent
// holds the session + CSRF token — see the bridge in notebook.js):
//
//   • kernel_phase breadcrumbs (boot_start → app_ready → kernel_starting →
//     kernel_idle) — the boot funnel; the drop-off point shows WHERE a boot
//     stalls. `kernel_idle` is the reliable "the kernel actually came up"
//     signal the parent-side probe could never get.
//   • kernel_error — the actual failure: a CSP worker block (the data:-worker
//     case), an IndexedDB / Drive exception, a blocked/404 asset, a dead/unknown
//     kernel, or a boot-stall watchdog — the WHY.
//
// Capture is scoped to the BOOT window (it stops once the kernel is idle), so it
// never records student-code execution — infrastructure breadcrumbs only, same
// PII contract as the rest of client-diagnostics.

(function () {
    'use strict';

    var KERNEL_BOOT_DEADLINE_MS = 75000;  // generous; a healthy kernel idles in seconds
    var SUSTAINED_UNHEALTHY_MS = 10000;   // ignore transient mid-boot dead/unknown blips
    var MAX_ERRORS = 8;

    var origin;
    try { origin = window.location.origin; } catch (_) { origin = '*'; }

    var reportedPhases = {};
    var seenErrors = {};
    var errorCount = 0;
    var done = false;                 // true once idle/stalled — stops the boot-window capture
    var lastPhase = 'boot_start';

    // Always posts to window.parent: in the editor that is the notebook page
    // (which forwards it); loaded top-level (the editor-smoke REPL) parent is
    // self, so a top-level listener can still observe it for testing.
    function post(kind, source, message) {
        try {
            var payload = { ck: 'kernel-diag', kind: kind, source: String(source).slice(0, 64) };
            if (message != null) payload.message = String(message).slice(0, 1000);
            window.parent.postMessage(payload, origin);
        } catch (_) { /* never throw */ }
    }

    function reportPhase(phase) {
        if (reportedPhases[phase]) return;
        reportedPhases[phase] = true;
        lastPhase = phase;
        post('kernel_phase', phase);
    }

    function reportError(source, message) {
        try {
            if (done) return;                 // boot window only — never student execution
            if (errorCount >= MAX_ERRORS) return;
            var key = source + '|' + (message || '');
            if (seenErrors[key]) return;
            seenErrors[key] = true;
            errorCount += 1;
            post('kernel_error', source, message);
        } catch (_) { /* never throw */ }
    }

    // ---- error capture (the WHY) ---------------------------------------

    try {
        // CSP violations — e.g. the data:-worker block ("worker-src 'self' blob:").
        window.addEventListener('securitypolicyviolation', function (e) {
            try {
                reportError(
                    'csp_violation',
                    (e.violatedDirective || 'csp') + ' blocked ' + String(e.blockedURI || '').slice(0, 200));
            } catch (_) { /* ignore */ }
        }, true);
    } catch (_) { /* ignore */ }

    try {
        // Capture phase: resource-load failures (blocked/404 kernel worker chunk,
        // wheel) don't bubble to a non-capturing listener.
        window.addEventListener('error', function (e) {
            try {
                var target = e && e.target;
                if (target && target !== window && (target.src || target.href)) {
                    reportError('resource_error',
                        'failed to load ' + String(target.src || target.href).slice(0, 200));
                } else if (e && e.message) {
                    reportError('onerror', e.message);
                }
            } catch (_) { /* ignore */ }
        }, true);
    } catch (_) { /* ignore */ }

    try {
        window.addEventListener('unhandledrejection', function (e) {
            try {
                var reason = e && e.reason;
                reportError('unhandledrejection', (reason && reason.message) || String(reason || 'unhandledrejection'));
            } catch (_) { /* ignore */ }
        });
    } catch (_) { /* ignore */ }

    // ---- boot-phase detection (the WHERE) ------------------------------
    //
    // This JupyterLite build (Notebook 7) does NOT expose window.jupyterapp, so
    // we read the kernel state from the DOM the shell renders — verified against
    // the real editor by the authenticated notebook-page smoke test. The notebook
    // execution indicator carries a structured data-status (idle/busy/starting),
    // with the "Kernel status: …" tooltip text as a secondary signal. (This is
    // also why the parent-side watchdog could never read kernel state: the global
    // it reaches for simply isn't there.) Cheap by design — a couple of
    // querySelectors — so the per-second poll never competes with the kernel.
    function shellReady() {
        try {
            if (document.querySelector('.jp-Notebook-ExecutionIndicator, .jp-NotebookPanel, .jp-Notebook')) {
                return true;
            }
            return document.querySelectorAll('[class^="jp-"],[class*=" jp-"]').length > 20;
        } catch (_) { return false; }
    }

    function kernelStatus() {
        try {
            // Primary: the execution indicator's data-status (idle/busy/starting/…).
            var ind = document.querySelector('.jp-Notebook-ExecutionIndicator[data-status]');
            if (ind) {
                var s = ind.getAttribute('data-status');
                if (s) return s;
            }
            if (document.querySelector('.jp-KernelStatus-error')) return 'unknown';
        } catch (_) { /* fall through */ }
        try {
            // Text fallback (console/REPL, or a layout change in a future build).
            var txt = (document.body && document.body.textContent) || '';
            if (txt.indexOf('Kernel status: Idle') !== -1 || txt.indexOf('Kernel status: Busy') !== -1
                || txt.indexOf('| Idle') !== -1 || txt.indexOf('| Busy') !== -1) {
                return 'idle';
            }
            if (txt.indexOf('Kernel status: Unknown') !== -1 || txt.indexOf('Kernel Unknown') !== -1) {
                return 'unknown';
            }
        } catch (_) { /* fall through */ }
        return null;
    }

    // Decide whether a dead/unknown kernel status has persisted long enough to
    // report. PURE (no globals beyond the constant) so it unit-tests cleanly.
    // A healthy boot routinely flashes "Kernel Unknown" for a beat before it
    // reaches idle, so a single unhealthy poll is noise — reporting it produced
    // a false kernel_unknown on most *successful* boots. So: start a clock on
    // the first unhealthy poll, report only once the state has held continuously
    // for SUSTAINED_UNHEALTHY_MS, and reset the clock the instant the status is
    // anything else (idle/busy/starting/null).
    //   status         — current kernelStatus() value (may be null)
    //   unhealthySince — ms timestamp the current streak began, or 0 if none
    //   now            — current time in ms
    // returns { unhealthySince, report }.
    function trackUnhealthy(status, unhealthySince, now) {
        if (status === 'dead' || status === 'unknown') {
            var since = unhealthySince || now;   // first unhealthy poll starts the clock
            return { unhealthySince: since, report: now - since >= SUSTAINED_UNHEALTHY_MS };
        }
        return { unhealthySince: 0, report: false };
    }

    var startedAt = Date.now();
    var unhealthySince = 0;   // ms timestamp the current dead/unknown streak began; 0 = healthy

    function poll() {
        if (done) return;
        try {
            if (!reportedPhases.app_ready && shellReady()) reportPhase('app_ready');
            var status = kernelStatus();
            if (status) {
                if (!reportedPhases.kernel_starting) reportPhase('kernel_starting');
                if (status === 'idle' || status === 'busy') {
                    reportPhase('kernel_idle');   // SUCCESS — the missing signal
                    done = true;
                    return;
                }
            }
            // Report dead/unknown only when it PERSISTS — runs every poll
            // (including status === null) so a momentary unknown that flips back
            // resets the clock and never reports.
            var tracked = trackUnhealthy(status, unhealthySince, Date.now());
            unhealthySince = tracked.unhealthySince;
            if (tracked.report) {
                reportError('kernel_' + status, 'kernel status ' + status);
                // keep watching — a recovery may still reach idle
            }
        } catch (_) { /* ignore */ }
        if (Date.now() - startedAt >= KERNEL_BOOT_DEADLINE_MS) {
            reportError('boot_stalled',
                'last_phase=' + lastPhase + ';elapsed_ms=' + (Date.now() - startedAt));
            done = true;     // stop; the funnel drop-off + captured errors tell the story
            return;
        }
        setTimeout(poll, 1000);
    }

    reportPhase('boot_start');
    setTimeout(poll, 500);

    // Test seam (Node vm): exercise detection + reporting without a browser.
    try {
        var hooks = (typeof globalThis !== 'undefined') && globalThis.__CK_KERNEL_DIAG_TEST_HOOKS__;
        if (hooks) hooks.exports = {
            kernelStatus: kernelStatus, reportPhase: reportPhase,
            reportError: reportError, trackUnhealthy: trackUnhealthy,
        };
    } catch (_) { /* ignore */ }
})();
