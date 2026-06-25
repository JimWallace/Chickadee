// Public/notebook-preflight.js
//
// Capability preflight + failure-handling glue for the student submit page.
//
// Two failure modes are handled identically once detected:
//   1. preflight_fail   — a capability the in-browser editor needs is
//                          disabled or blocked (no service workers, no
//                          IndexedDB, WebAssembly disabled, etc.).
//   2. watchdog_timeout — the iframe loaded but the JupyterLite kernel
//                          didn't become ready within the watchdog window.
//
// On either failure: hide the iframe, reveal the #nb-fallback section
// containing a direct .ipynb upload picker, and POST a record to
// /api/v1/client-diagnostics so the instructor dashboard can surface the
// affected student.
//
// When all preflight checks pass, this script makes ZERO visible changes to
// the page — the iframe loads normally and the watchdog is silently armed
// by notebook.js.
//
// Loaded before notebook.js on Resources/Views/notebook.leaf.

(function () {
    'use strict';

    const PREFLIGHT_DIAGNOSTICS_URL = '/api/v1/client-diagnostics';

    // ----------------------------------------------------------------
    // Preflight checks
    // ----------------------------------------------------------------

    /**
     * Runs all capability checks against the current browser.
     * Returns { ok: bool, failed: string[] }.
     */
    async function runPreflight() {
        const failed = [];

        if (typeof WebAssembly === 'undefined')      failed.push('WebAssembly');
        if (!('Worker'        in window))            failed.push('Worker');
        if (!('serviceWorker' in (navigator || {}))) failed.push('serviceWorker');
        if (!('indexedDB'     in window))            failed.push('indexedDB');

        // Real registration test: SW API may be present but policy may block
        // registration (corporate-managed Edge/Chrome, Safari private mode).
        if (failed.indexOf('serviceWorker') === -1) {
            try {
                const reg = await navigator.serviceWorker.register(
                    '/sw-preflight.js',
                    { scope: '/sw-preflight/' }
                );
                try { await reg.unregister(); } catch (_) { /* best effort */ }
            } catch (e) {
                failed.push('serviceWorker:register');
            }
        }

        // Real IndexedDB open test: API may be present but storage blocked
        // (private mode, "block all site data", quota exhausted).
        if (failed.indexOf('indexedDB') === -1) {
            try {
                await new Promise(function (resolve, reject) {
                    const r = indexedDB.open('chickadee_preflight', 1);
                    r.onsuccess = function () {
                        try {
                            r.result.close();
                            indexedDB.deleteDatabase('chickadee_preflight');
                        } catch (_) { /* best effort */ }
                        resolve();
                    };
                    r.onerror   = function () { reject(r.error || new Error('open failed')); };
                    r.onblocked = function () { reject(new Error('blocked')); };
                });
            } catch (e) {
                failed.push('indexedDB:open');
            }
        }

        // Proactive low-memory hint (non-blocking — NOT a `failed` capability).
        // `navigator.deviceMemory` is GB rounded to a power of two, and is exposed
        // on Chromium only (Safari/Firefox omit it for fingerprinting privacy), so
        // this catches low-RAM Chromebooks/Android but can't see iOS — the runtime
        // `wasm_crash` recovery covers the WebKit case where this signal is absent.
        var dm = (navigator && typeof navigator.deviceMemory === 'number') ? navigator.deviceMemory : null;
        var lowMemory = (dm !== null && dm > 0 && dm <= 2);

        return { ok: failed.length === 0, failed: failed, lowMemory: lowMemory, deviceMemory: dm };
    }

    // ----------------------------------------------------------------
    // Failure UI + diagnostic post
    // ----------------------------------------------------------------

    let _failureShown = false;

    /**
     * Hide the editor iframe, reveal the fallback panel, and POST a
     * diagnostic record.  Idempotent — calling twice (e.g. preflight
     * failed AND the unmounted iframe later "timed out") only renders
     * once and only posts the first kind.
     *
     * @param {{kind: string, failedChecks?: string[]}} info
     */
    function showFailure(info) {
        if (_failureShown) return;
        _failureShown = true;

        const frame    = document.getElementById('jl-frame');
        const fallback = document.getElementById('nb-fallback');
        const details  = document.getElementById('nb-fallback-details');
        const submit   = document.getElementById('nb-submit');

        if (frame)    frame.style.display = 'none';
        if (submit)   submit.style.display = 'none';
        if (fallback) fallback.hidden = false;

        // Memory-crash variant: the editor DID load, but the kernel died on a
        // fatal WASM/OOM crash mid-session — swap in memory-specific copy on the
        // same fallback panel (which already offers .ipynb upload + reset link),
        // instead of the generic "Editor didn't load" message.
        if (info.variant === 'memory' && fallback) {
            const titleEl = fallback.querySelector('.nb-fallback-title');
            const textEl  = fallback.querySelector('.nb-fallback-text');
            if (titleEl) titleEl.textContent = 'Your browser ran low on memory';
            if (textEl) {
                textEl.textContent =
                    'The Python kernel stopped because your browser hit a memory limit — ' +
                    'common on Safari and on phones, tablets, or low-memory computers. ' +
                    'Reload to try again, or open this assignment on a laptop or desktop in ' +
                    'Chrome or Firefox. You can also submit by uploading your .ipynb file below.';
            }
        }

        // Point the "reset the notebook editor" link back at THIS assignment, so
        // after clearing site data the student lands on the same page (which now
        // boots a clean kernel) instead of the dashboard.  The static href in the
        // template ("/reset-editor") is the no-JS fallback.
        const resetLink = document.getElementById('nb-reset-editor-link');
        if (resetLink) {
            try {
                resetLink.href = '/reset-editor?next=' +
                    encodeURIComponent(location.pathname + location.search);
            } catch (_) { /* keep the static href */ }
        }

        if (details) {
            const lines = [
                'Failure: ' + info.kind,
                'User-Agent: ' + (navigator.userAgent || '(unknown)'),
            ];
            if (info.failedChecks && info.failedChecks.length) {
                lines.push('Failed checks: ' + info.failedChecks.join(', '));
            }
            details.textContent = lines.join('\n');
        }

        postDiagnostic(info).catch(function (err) {
            // Last-resort log only; we already showed the fallback UI.
            if (window.console) console.warn('[preflight] diagnostic post failed:', err);
        });
    }

    async function postDiagnostic(info) {
        const frame     = document.getElementById('jl-frame');
        const setupID   = frame && frame.dataset ? frame.dataset.setupId : null;
        const csrfToken = (typeof getCsrfToken === 'function') ? getCsrfToken() : '';

        const body = { kind: info.kind };
        if (info.failedChecks && info.failedChecks.length) body.failedChecks = info.failedChecks;
        if (setupID) body.testSetupID = setupID;
        // Error detail (editor_error + kernel-unhealthy watchdog).  Client-side
        // caps are generous; the server trims to its own bounds.
        if (info.message) body.message = String(info.message).slice(0, 2000);
        if (info.stack)   body.stack   = String(info.stack).slice(0, 8000);
        if (info.source)  body.source  = String(info.source).slice(0, 64);

        await fetch(PREFLIGHT_DIAGNOSTICS_URL, {
            method:  'POST',
            credentials: 'same-origin',
            headers: {
                'content-type':  'application/json',
                'x-csrf-token':  csrfToken
            },
            body: JSON.stringify(body)
        });
    }

    // ----------------------------------------------------------------
    // Editor-error telemetry
    // ----------------------------------------------------------------
    //
    // Unlike showFailure(), this makes NO visible change to the page — an
    // uncaught error on the editor page isn't necessarily fatal — it just
    // posts an "editor_error" diagnostic so we can see what broke.  Capped and
    // de-duplicated per page load so a tight error loop can't flood the
    // endpoint (the server also rate-limits per (user, setup, kind, source)).

    const _reportedErrors = new Set();
    let _errorReportCount = 0;
    const MAX_ERROR_REPORTS = 8;

    function reportEditorError(info) {
        try {
            if (!info || _errorReportCount >= MAX_ERROR_REPORTS) return;
            const dedupeKey = (info.source || '') + '|' + (info.message || '');
            if (_reportedErrors.has(dedupeKey)) return;
            _reportedErrors.add(dedupeKey);
            _errorReportCount += 1;

            postDiagnostic({
                kind:    'editor_error',
                source:  info.source,
                message: info.message,
                stack:   info.stack
            }).catch(function () { /* telemetry is best-effort */ });
        } catch (_) {
            // Never let telemetry throw inside an error handler.
        }
    }

    // ----------------------------------------------------------------
    // Non-error event telemetry
    // ----------------------------------------------------------------
    //
    // Fire-and-forget beacon for NON-failure editor events — the success
    // denominator (`editor_ready`) and service-worker state (`sw_state`).
    // Like reportEditorError it makes NO visible change to the page; it just
    // lets us compute an editor *success rate* and diagnose the SW path,
    // instead of only counting failures.

    function reportEvent(info) {
        try {
            if (!info || !info.kind) return;
            postDiagnostic(info).catch(function () { /* telemetry is best-effort */ });
        } catch (_) {
            // Never let telemetry throw.
        }
    }

    // ----------------------------------------------------------------
    // Proactive low-memory warning (non-blocking)
    // ----------------------------------------------------------------
    //
    // Shown when the preflight PASSES but `navigator.deviceMemory` reports a
    // low-RAM device. Reveals a dismissible banner WITHOUT hiding the editor —
    // the student can still work; it just sets expectations. Dismissal persists
    // per-device (localStorage) so it doesn't nag on every visit. The
    // `device_warning` beacon fires regardless of dismissal, which also gives us
    // the real low-memory-device rate to calibrate against.

    let _deviceWarningShown = false;
    function showDeviceWarning(info) {
        if (_deviceWarningShown) return;
        _deviceWarningShown = true;
        const dm = (info && typeof info.deviceMemory === 'number') ? info.deviceMemory : null;

        let dismissed = false;
        try { dismissed = localStorage.getItem('ck_device_warn_dismissed') === '1'; } catch (_) { /* ignore */ }

        const banner = document.getElementById('nb-device-warning');
        if (banner && !dismissed) {
            banner.hidden = false;
            const closeBtn = document.getElementById('nb-device-warning-dismiss');
            if (closeBtn) {
                closeBtn.addEventListener('click', function () {
                    banner.hidden = true;
                    try { localStorage.setItem('ck_device_warn_dismissed', '1'); } catch (_) { /* ignore */ }
                });
            }
        }

        // Telemetry fires even if the banner was previously dismissed.
        reportEvent({
            kind:    'device_warning',
            source:  'low_memory',
            message: 'deviceMemory=' + (dm !== null ? dm : 'unknown')
        });
    }

    // ----------------------------------------------------------------
    // Public surface
    // ----------------------------------------------------------------

    window.ChickadeeNotebookFailures = {
        runPreflight:      runPreflight,
        showFailure:       showFailure,
        showDeviceWarning: showDeviceWarning,
        reportEditorError: reportEditorError,
        reportEvent:       reportEvent
    };
})();
