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

        return { ok: failed.length === 0, failed: failed };
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
    // Public surface
    // ----------------------------------------------------------------

    window.ChickadeeNotebookFailures = {
        runPreflight: runPreflight,
        showFailure:  showFailure
    };
})();
