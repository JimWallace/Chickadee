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
//     signal the parent-side probe could never get. A `kernel_idle` that follows
//     a previously-reported unhealthy streak carries `recovered=1;unhealthy_ms=…`
//     so a transient slow boot can be told apart from a terminal stall (CASE 2):
//     terminal kernel_unknown = (kernel_unknown count) − (recovered=1 idles).
//   • kernel_error — the actual failure: a CSP worker block (the data:-worker
//     case), an IndexedDB / Drive exception, a blocked/404 asset, a dead/unknown
//     kernel, a boot-stall watchdog, or a post-idle execution hang
//     (source `exec_hang`) — the WHY. The boot-window watchdog beacons
//     (kernel_unknown / boot_stalled) additionally append a PII-safe environment
//     snapshot (`bootContext()`: coi/sab/deviceMemory/cores/SW-control/shell/
//     error-trail/last-phase) so a single stalled-kernel row is self-diagnostic
//     instead of a bare "kernel status unknown" with no root cause.
//
// Boot-window error capture (CSP / resource / unhandledrejection / dead-unknown /
// boot-stall) stops the instant the kernel reaches idle, so it never records
// student-code execution. AFTER idle, ONE narrow watcher remains: it polls only
// the kernel's busy/idle status indicator (never the notebook content) and emits
// a single `exec_hang` when a cell sits `busy` past EXEC_HANG_MS — the post-idle
// hang the boot funnel goes blind on (the kernel booted fine, then wedged on
// execute, so `kernel_idle` already reported "success"). It transmits a duration
// only (`busy_ms=…`), never code or output — same PII contract as the rest of
// client-diagnostics.

(function () {
    'use strict';

    var KERNEL_BOOT_DEADLINE_MS = 75000;  // generous; a healthy kernel idles in seconds
    var SUSTAINED_UNHEALTHY_MS = 30000;   // only a genuinely-stuck kernel sits unhealthy this long — slow-but-fine boots recover well under it (production bootContext showed recoveries at unhealthy_ms 12-37s on 32GB Chrome and modern Safari, so 10s was flagging healthy slow boots)
    var MAX_ERRORS = 8;
    var EXEC_HANG_MS = 45000;     // a cell BUSY this long post-idle is a hang, not a slow cell
    var POST_IDLE_MAX_MS = 900000;  // watch the post-idle exec window this long, then stop (hygiene)

    var origin;
    try { origin = window.location.origin; } catch (_) { origin = '*'; }

    var reportedPhases = {};
    var seenErrors = {};
    var errorCount = 0;
    var done = false;                 // true once idle/stalled — stops the boot-window capture
    var lastPhase = 'boot_start';
    var lastErrorSource = '';         // most recent captured error source — fed to bootContext()

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

    function reportPhase(phase, message) {
        if (reportedPhases[phase]) return;
        reportedPhases[phase] = true;
        lastPhase = phase;
        post('kernel_phase', phase, message);
    }

    function reportError(source, message) {
        try {
            if (done) return;                 // boot window only — never student execution
            if (errorCount >= MAX_ERRORS) return;
            var key = source + '|' + (message || '');
            if (seenErrors[key]) return;
            seenErrors[key] = true;
            errorCount += 1;
            lastErrorSource = source;
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

    // ---- fatal WASM / OOM crash (the kernel DIED) ----------------------
    //
    // The fatal upstream WebKit/Safari WASM crash (WebKit #286266 — "Out of
    // bounds memory access" in __pyproxy_apply) and genuine WASM OOM aborts kill
    // the kernel mid-execute, which is AFTER the boot window — so the done-gated
    // reportError() above deliberately ignores them. A dead kernel always
    // matters, so capture the fatal-crash signature separately: NOT done-gated,
    // one-shot, forwarded as a distinct `wasm_crash` source the parent turns into
    // a memory-specific recovery notice (instead of a silently wedged cell).
    var WASM_CRASH_RE = /out of bounds memory access|Pyodide has suffered a fatal error|__pyproxy_apply|RangeError: Bad value|abort\(.*[Oo]ut of memory|abort\(OOM\)|memory access out of bounds/;
    var wasmCrashReported = false;
    function reportWasmCrashIfMatch(message) {
        try {
            if (wasmCrashReported) return;
            var msg = String(message || '');
            if (!WASM_CRASH_RE.test(msg)) return;
            wasmCrashReported = true;
            post('kernel_error', 'wasm_crash', msg);
        } catch (_) { /* never throw */ }
    }
    try {
        window.addEventListener('unhandledrejection', function (e) {
            try {
                var reason = e && e.reason;
                reportWasmCrashIfMatch((reason && reason.message) || String(reason || ''));
            } catch (_) { /* ignore */ }
        });
        window.addEventListener('error', function (e) {
            try { if (e && e.message) reportWasmCrashIfMatch(e.message); } catch (_) { /* ignore */ }
        }, true);
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

    // Environment / capability snapshot for the WHY of a stalled or unknown
    // kernel. Appended ONLY to the boot-window watchdog beacons (kernel_unknown /
    // boot_stalled), which fire BEFORE idle — so, like the rest of the boot-window
    // capture, this reads no student content. It records device-class and
    // platform-capability signals (the same class of data the server already
    // derives from the User-Agent) plus the in-iframe error trail — never code,
    // output, grades, or identity:
    //   coi/sab  — crossOriginIsolated + SharedArrayBuffer (which kernel transport
    //              path: COI threads vs. comlink/SW fallback; the WebKit split)
    //   mem/cpu  — navigator.deviceMemory / hardwareConcurrency (the low-RAM /
    //              old-iPad terminal-stall hypothesis)
    //   swctl    — is a service worker controlling the document (asset serving)
    //   shell    — did the JupyterLite shell render at all (app vs. kernel stall)
    //   errs     — how many boot errors were captured before the watchdog fired
    //   lasterr  — the last captured error source (did a csp_violation /
    //              resource_error / wasm crash precede the stall?)
    //   phase    — the furthest boot phase reached
    // Fully guarded: a missing navigator / global yields a fallback token (`na` /
    // `false`), never a throw — the diagnostics must never break the editor.
    function bootContext() {
        var parts = [];
        try {
            var win = (typeof window !== 'undefined') ? window : {};
            var nav = win.navigator || {};
            parts.push('coi=' + (win.crossOriginIsolated === true));
            parts.push('sab=' + (typeof win.SharedArrayBuffer !== 'undefined'));
            parts.push('mem=' + (nav.deviceMemory != null ? nav.deviceMemory : 'na'));
            parts.push('cpu=' + (nav.hardwareConcurrency != null ? nav.hardwareConcurrency : 'na'));
            parts.push('swctl=' + !!(nav.serviceWorker && nav.serviceWorker.controller));
            parts.push('shell=' + shellReady());
            parts.push('errs=' + errorCount);
            parts.push('lasterr=' + (lastErrorSource || 'none'));
            parts.push('phase=' + lastPhase);
        } catch (_) { /* never throw — return whatever was gathered */ }
        return parts.join(';');
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

    // Raw execution-indicator status for the post-idle watcher: ONLY the
    // structured data-status (idle/busy/starting/…), never the body-text fallback
    // — after idle the page body holds the student's code/output, and this watcher
    // must read infrastructure state only. Returns null when the indicator is
    // absent (the watcher then reports nothing: graceful, no false positive, no
    // content scan).
    function executionStatusRaw() {
        try {
            var ind = document.querySelector('.jp-Notebook-ExecutionIndicator[data-status]');
            if (ind) return ind.getAttribute('data-status');
        } catch (_) { /* ignore */ }
        return null;
    }

    // Decide whether the kernel has been continuously BUSY long enough to be a
    // hang rather than a slow cell. PURE, mirrors trackUnhealthy. Start a clock on
    // the first busy poll; flag once busy has held for EXEC_HANG_MS; any non-busy
    // status (idle/starting/null — a finished cell or none running) resets it.
    //   status        — raw execution-indicator status (may be null)
    //   execBusySince — ms timestamp the current busy run began, or 0 if none
    //   now           — current time in ms
    // returns { execBusySince, hang }.
    function trackExecHang(status, execBusySince, now) {
        if (status === 'busy') {
            var since = execBusySince || now;
            return { execBusySince: since, hang: now - since >= EXEC_HANG_MS };
        }
        return { execBusySince: 0, hang: false };
    }

    // Compose the kernel_idle phase message. PURE (mirrors trackUnhealthy /
    // trackExecHang). A boot that first emitted a sustained kernel_unknown/dead and
    // THEN reached idle is tagged `recovered=1;unhealthy_ms=…` — this is the seam
    // that separates a transient CASE-2 blip (the watchdog cried wolf on a slow but
    // ultimately-healthy boot) from a terminal stall. Without the tag the two were
    // indistinguishable in the kernel_unknown count.
    //   elapsedMs         — total boot time boot_start → idle
    //   unhealthyReported — did this boot already beacon a kernel_unknown/dead?
    //   unhealthyMs       — how long that reported unhealthy streak lasted
    function idleMessage(elapsedMs, unhealthyReported, unhealthyMs) {
        var m = 'elapsed_ms=' + elapsedMs;
        if (unhealthyReported) m += ';recovered=1;unhealthy_ms=' + unhealthyMs;
        return m;
    }

    var startedAt = Date.now();
    var unhealthySince = 0;   // ms timestamp the current dead/unknown streak began; 0 = healthy
    var unhealthyReported = false;  // true once a sustained kernel_unknown/dead was beaconed
    var unhealthyReportedSince = 0; // streak start of that reported run (for recovered=1 / unhealthy_ms)
    var execBusySince = 0;        // ms timestamp the current post-idle busy run began; 0 = idle
    var execHangReported = false; // de-dupe: one exec_hang per page
    var execWatchStartedAt = 0;

    // Post-idle execution-hang watcher. Starts the instant the kernel reaches idle
    // (handed off from poll, which has stopped). Reads ONLY the busy/idle indicator
    // and reports a SINGLE `exec_hang` (duration only — never student content) when
    // a cell hangs busy past EXEC_HANG_MS: the post-idle case the boot funnel can't
    // see. Stops after the first report or POST_IDLE_MAX_MS, whichever is first.
    function watchExec() {
        try {
            var now = Date.now();
            if (now - execWatchStartedAt >= POST_IDLE_MAX_MS) return;
            var tracked = trackExecHang(executionStatusRaw(), execBusySince, now);
            execBusySince = tracked.execBusySince;
            if (tracked.hang && !execHangReported) {
                execHangReported = true;
                // PII-safe: kernel busy-duration only — never student code/output.
                // Reuses the kernel_error kind so the existing parent bridge +
                // server forward it unchanged; source `exec_hang` distinguishes it.
                post('kernel_error', 'exec_hang', 'busy_ms=' + (now - tracked.execBusySince));
                return;   // one report per page; stop watching
            }
        } catch (_) { /* never throw */ }
        setTimeout(watchExec, 2000);
    }

    function poll() {
        if (done) return;
        try {
            // Each phase carries elapsed_ms since boot_start, so the parent gets
            // a phase-localized boot-time breakdown (shell vs kernel) and we can
            // see the distribution — is a 2-min boot a freak or a fat tail?
            if (!reportedPhases.app_ready && shellReady()) {
                reportPhase('app_ready', 'elapsed_ms=' + (Date.now() - startedAt));
            }
            var status = kernelStatus();
            if (status) {
                if (!reportedPhases.kernel_starting) {
                    reportPhase('kernel_starting', 'elapsed_ms=' + (Date.now() - startedAt));
                }
                if (status === 'idle' || status === 'busy') {
                    // SUCCESS — the missing signal. elapsed_ms is the total kernel
                    // boot time (boot_start → idle). A boot that recovered from a
                    // previously-reported unhealthy streak is tagged recovered=1 so
                    // a transient CASE-2 blip isn't counted as a terminal failure.
                    reportPhase('kernel_idle', idleMessage(
                        Date.now() - startedAt, unhealthyReported,
                        unhealthyReportedSince ? Date.now() - unhealthyReportedSince : 0));
                    done = true;
                    // Boot capture stops here; hand off to the post-idle hang
                    // watcher (status-only, PII-safe) so the blind spot after idle
                    // — a kernel that booted then wedged on execute — is covered.
                    execWatchStartedAt = Date.now();
                    setTimeout(watchExec, 2000);
                    return;
                }
            }
            // Report dead/unknown only when it PERSISTS — runs every poll
            // (including status === null) so a momentary unknown that flips back
            // resets the clock and never reports.
            var tracked = trackUnhealthy(status, unhealthySince, Date.now());
            unhealthySince = tracked.unhealthySince;
            if (tracked.report && !unhealthyReported) {
                unhealthyReported = true;
                unhealthyReportedSince = tracked.unhealthySince;   // streak start
                // The WHY: kernel state + environment/capabilities + the error
                // trail that preceded the stall, captured once at first report.
                // Once-guarded (not just dedup'd) so the varying context can't
                // bypass the seenErrors key and beacon a kernel_unknown per poll.
                reportError('kernel_' + status, 'kernel status ' + status + ';' + bootContext());
                // keep watching — a recovery may still reach idle (tags recovered=1)
            }
        } catch (_) { /* ignore */ }
        if (Date.now() - startedAt >= KERNEL_BOOT_DEADLINE_MS) {
            reportError('boot_stalled',
                'last_phase=' + lastPhase + ';elapsed_ms=' + (Date.now() - startedAt)
                    + ';' + bootContext());
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
            trackExecHang: trackExecHang, executionStatusRaw: executionStatusRaw,
            bootContext: bootContext, idleMessage: idleMessage,
        };
    } catch (_) { /* ignore */ }
})();
