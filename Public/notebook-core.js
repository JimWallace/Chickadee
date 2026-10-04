// Public/notebook-core.js
//
// The pure rules behind the notebook page (notebook.js), in three groups:
//   - Editor readiness and kernel recovery. The watchdog reads the editor
//     iframe with these probes. Then it asks which recovery step comes next.
//   - Reseed planning. The notebook sync uses these decisions. They tell it
//     when the server copy replaces the copy in the browser.
//   - Results formatting. The inline results table gets its test names and
//     messages from these functions.
// The rules do not touch the page DOM, `window`, `navigator`, `fetch` or
// storage. The probes read only the iframe or window that the caller gives
// them. This lets the rules run under node (notebook.test.mjs,
// watchdog-probe.test.mjs, sync-force-reseed.test.mjs).
(function () {
    'use strict';

    // -------------------------------------------------------------------------
    // Editor readiness and kernel recovery (armEditorWatchdog in notebook.js)
    // -------------------------------------------------------------------------

    // Probes the JupyterLite iframe for shell readiness + kernel failure
    // evidence using a layered approach.  Each layer is wrapped in
    // try/catch so a cross-origin or transient access error doesn't kill
    // the watchdog.
    //
    // For shell readiness, we accept ANY of:
    //   * `frame.contentWindow.jupyterapp` truthy  — works in Chromium
    //   * a JupyterLab toolbar element in the iframe's DOM
    //   * any `.jp-` prefixed class on the iframe's body
    // The DOM checks work in Safari where the JS-property probe doesn't.
    //
    // For kernel state, we look for POSITIVE EVIDENCE OF FAILURE only:
    //   * "Kernel Unknown" text in the iframe DOM (Hans's symptom)
    //   * a session with status `dead` or `unknown` via ServiceManager
    // Absence of failure evidence is NOT treated as failure — kernels
    // that are still bootstrapping ("starting", "connecting") look the
    // same to us as healthy ones, and that's fine; the watchdog only
    // fires when we're sure something has broken.
    function probeIframeReadiness(frame) {
        let shellReady = false;
        let kernelReady = false;
        let kernelInFailureState = false;
        let kernelEvidence = null;
        let win = null;
        let doc = null;

        try { win = frame.contentWindow; } catch (_) { /* nope */ }
        try { doc = frame.contentDocument; } catch (_) { /* nope */ }

        // Probe 1: JS global on contentWindow (Chromium-friendly)
        try {
            if (win && win.jupyterapp) {
                shellReady = true;
                const evidence = kernelFailureEvidence(win);
                if (evidence) {
                    kernelInFailureState = true;
                    kernelEvidence = evidence;
                }
            }
        } catch (_) { /* fall through */ }

        // Probe 2: DOM presence in the iframe (Safari-friendly)
        if (!shellReady) {
            try {
                if (doc && doc.body) {
                    if (doc.querySelector('.jp-Toolbar') ||
                        doc.querySelector('.jp-Notebook') ||
                        doc.querySelector('[class^="jp-"]') ||
                        doc.querySelector('[class*=" jp-"]')) {
                        shellReady = true;
                    }
                }
            } catch (_) { /* fall through */ }
        }

        // Probe 3: kernel failure by DOM text (covers Safari where the
        // JS-API path returns nothing).  We specifically look for the
        // "Kernel Unknown" badge JupyterLite shows when the kernel
        // session failed to register.
        if (shellReady && !kernelInFailureState) {
            try {
                const txt = (doc && doc.body && doc.body.textContent) || '';
                if (txt.indexOf('Kernel Unknown') !== -1) {
                    kernelInFailureState = true;
                    kernelEvidence = 'Kernel Unknown badge (iframe dom)';
                }
            } catch (_) { /* fall through */ }
        }

        // Positive kernel liveness (independent of failure evidence): a running
        // session in idle/busy, or the "| Idle"/"| Busy" status text. Absence
        // is "unknown", never "ready" — so kernel_ready never false-positives.
        if (shellReady) {
            kernelReady = kernelLivenessReady(win, doc);
        }
        return { shellReady, kernelReady, kernelInFailureState, kernelEvidence };
    }

    // Returns a short evidence string iff we have POSITIVE EVIDENCE the
    // kernel has hit a known failure state, or null otherwise.  Used by the
    // watchdog to decide whether to fire phase-2 ("kernel-unhealthy") and to
    // attach a diagnosable reason to the diagnostic.  We deliberately return
    // null for the "I don't know" case — kernels that are still bootstrapping
    // look the same as healthy ones to us, and that's fine.  We'd rather miss a
    // genuine failure than false-positive on a working editor.
    //
    // Failure signals (any of):
    //   * ServiceManager session with status `dead` or `unknown`
    //   * "Kernel Unknown" text in the iframe DOM (the Hans symptom)
    //
    // Each probe is wrapped in try/catch so a TypeError or cross-origin
    // access error doesn't propagate.
    function kernelFailureEvidence(win) {
        try {
            const app = win.jupyterapp;
            const sm  = app && app.serviceManager;
            if (sm && sm.sessions && typeof sm.sessions.running === 'function') {
                const running = sm.sessions.running();
                if (running) {
                    const sessions = Array.from(running);
                    for (let i = 0; i < sessions.length; i++) {
                        const status = sessions[i] && sessions[i].kernel && sessions[i].kernel.status;
                        if (status === 'unknown' || status === 'dead') {
                            return 'kernel status: ' + status;
                        }
                    }
                }
            }
        } catch (_) { /* fall through */ }

        try {
            const doc = win.document;
            const txt = (doc && doc.body && doc.body.textContent) || '';
            if (txt.indexOf('Kernel Unknown') !== -1) return 'Kernel Unknown badge';
        } catch (_) { /* fall through */ }

        return null;
    }

    // Returns true iff we have POSITIVE evidence the kernel is ALIVE — a running
    // session reporting idle/busy, or the "| Idle"/"| Busy" status text in the
    // iframe DOM. Absence is "unknown" (still booting, or an unprobeable
    // cross-process Safari iframe), never "ready" — so the kernel_ready success
    // signal never false-positives on a working-but-unprobeable editor.
    function kernelLivenessReady(win, doc) {
        try {
            const app = win && win.jupyterapp;
            const sm  = app && app.serviceManager;
            if (sm && sm.sessions && typeof sm.sessions.running === 'function') {
                const running = sm.sessions.running();
                if (running) {
                    const sessions = Array.from(running);
                    for (let i = 0; i < sessions.length; i++) {
                        const status = sessions[i] && sessions[i].kernel && sessions[i].kernel.status;
                        if (status === 'idle' || status === 'busy') return true;
                    }
                }
            }
        } catch (_) { /* fall through */ }
        try {
            const text = (doc && doc.body && doc.body.textContent) || '';
            if (text.indexOf('| Idle') !== -1 || text.indexOf('| Busy') !== -1) return true;
        } catch (_) { /* fall through */ }
        return false;
    }

    // Decides how the watchdog reacts to POSITIVE EVIDENCE that the kernel is
    // in a failure state (`dead` / `unknown` session, or the "Kernel Unknown"
    // badge).  Pure so it's unit-testable; the caller performs the reload /
    // showFailure side effects.
    //
    // The Pyodide kernel's synchronous-execution path (Drive + stdin) is served
    // by the JupyterLite service worker, so a kernel that boots while the SW is
    // registered-but-not-yet-*controlling* lands in "Kernel Unknown".  That race
    // is usually transient, so we escalate through two reload rungs before
    // giving up:
    //
    //   * First failure  → 'reload-iframe': reload just the editor iframe.  The
    //                      cheapest recovery; clears most cold-boot races.
    //   * Second failure → 'reload-page': the iframe reload re-raced.  Reload
    //                      the whole tab once — only a full document load
    //                      re-bootstraps the SW→client control relationship from
    //                      scratch (an in-place iframe `src` reset cannot), which
    //                      is what was missing when failures "persisted after
    //                      auto-reload".  Guarded by the caller (one per tab
    //                      session) so it can't loop.
    //   * Third failure  → 'fail': neither reload helped.  Surface the upload
    //                      fallback and report the diagnostic, with the message
    //                      annotated so telemetry can distinguish a persistent
    //                      kernel failure from a first-try one.  The kind /
    //                      failedChecks / source are unchanged so the admin
    //                      browser-diagnostics breakdown keeps classifying it.
    function planKernelFailureResponse({ iframeReloadAttempted, pageReloadAttempted, evidence }) {
        if (!iframeReloadAttempted) {
            return { action: 'reload-iframe' };
        }
        if (!pageReloadAttempted) {
            return { action: 'reload-page' };
        }
        const reason = evidence || 'kernel in failure state';
        return {
            action: 'fail',
            diagnostic: {
                kind:         'watchdog_timeout',
                failedChecks: ['kernel-unhealthy'],
                source:       'kernel',
                message:      reason + ' (persisted after auto-reload)'
            }
        };
    }

    // -------------------------------------------------------------------------
    // Reseed planning (syncNotebookFromServerSnapshot in notebook.js)
    // -------------------------------------------------------------------------

    // Pure decision function used by `syncNotebookFromServerSnapshot` to
    // decide whether to force-overwrite the browser's IndexedDB copy
    // with the server snapshot, OR preserve the local copy and let the
    // student's in-progress edits stand.
    //
    //   serverMtime  — Unix-epoch seconds of the working-copy file on
    //                  the server.  0 if the server couldn't stat it.
    //   seenMtime    — Unix-epoch seconds of the last server mtime this
    //                  browser observed, persisted in localStorage.  0
    //                  if no baseline has been recorded yet (first visit
    //                  ever, or first visit after this code deployed).
    //
    // Returns true iff we should treat the server file as "freshly
    // overwritten since we last looked" and discard the local IndexedDB
    // copy.  Returns false when we have no baseline (seenMtime === 0),
    // because absence of a baseline must NOT mean "any server mtime is
    // newer" — that would clobber every student's pre-existing local
    // work on the first post-deploy visit.
    function shouldForceReseed({ serverMtime, seenMtime }) {
        if (!serverMtime || serverMtime <= 0) return false;
        if (!seenMtime  || seenMtime  <= 0) return false;
        return serverMtime > seenMtime;
    }

    // Pure decision used by `syncNotebookFromServerSnapshot` to turn the
    // two observations (do we already hold a local copy? did the server
    // overwrite the file since we last looked?) into an action plan.
    //
    //   shouldSeed    — write the server snapshot into the IndexedDB
    //                   contents store.  True when there's no local copy
    //                   (first visit / different device) OR the server is
    //                   newer (instructor/self reset).
    //   reloadOpenDoc — after seeding, force an already-open document
    //                   widget to re-read the freshly-seeded contents.
    //                   Only on a server-newer reset: a first-time seed
    //                   opens the doc fresh anyway, and a preserve case
    //                   must NOT reload or it would wipe the student's
    //                   unsaved in-editor edits.
    function reseedPlan({ hasLocalContent, serverIsNewer }) {
        const shouldSeed = !hasLocalContent || serverIsNewer;
        return {
            shouldSeed,
            // Only a copy we already held (and the workspace already
            // re-opened) can be stale on screen.  With no local copy the
            // `docmanager:open` below loads the freshly-seeded contents
            // directly, so there's nothing to revert.
            reloadOpenDoc: !!hasLocalContent && !!serverIsNewer,
        };
    }

    // -------------------------------------------------------------------------
    // Results formatting (renderResults in notebook.js)
    // -------------------------------------------------------------------------

    function buildOutcomeDisplayNameMap(outcomes) {
        const map = new Map();
        for (const outcome of outcomes || []) {
            const displayName = bestOutcomeDisplayName(outcome);
            const keys = [outcome && outcome.scriptName, outcome && outcome.testName];
            for (const key of keys) {
                if (typeof key === 'string' && key.trim()) {
                    map.set(key.trim(), displayName);
                    const stem = key.replace(/\.[^.]+$/, '').trim();
                    if (stem) map.set(stem, displayName);
                }
            }
        }
        return map;
    }

    function bestOutcomeDisplayName(outcome) {
        const explicit = trimmedString(outcome && outcome.displayName);
        if (explicit) return explicit;
        const testName = trimmedString(outcome && outcome.testName);
        if (testName) return testName;
        return trimmedString(outcome && outcome.scriptName) || 'test';
    }

    function formattedOutcomeShortResult(outcome) {
        const shortResult = trimmedString(outcome && outcome.shortResult);
        const parsed = parseStructuredPayload(shortResult)
            || parseStructuredPayload(trimmedString(outcome && outcome.longResult));
        if (parsed) {
            const summary = structuredSummaryText(parsed, outcome && outcome.status);
            if (summary) return summary;
        }
        return shortResult || defaultShortResult(outcome && outcome.status);
    }

    function formattedOutcomeDetailedOutput(outcome) {
        const longResult = trimmedString(outcome && outcome.longResult);
        const shortResult = trimmedString(outcome && outcome.shortResult);
        const parsed = parseStructuredPayload(longResult) || parseStructuredPayload(shortResult);
        const traceback = extractTracebackText(parsed)
            || extractTracebackText(longResult)
            || extractTracebackText(shortResult);
        if (traceback) return traceback;
        return longResult || null;
    }

    function structuredSummaryText(payload, status) {
        if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return null;

        if (status && status !== 'pass') {
            for (const key of ['error', 'message', 'detail', 'reason']) {
                const text = trimmedString(payload[key]);
                if (text) return text;
            }
        }

        const shortResult = trimmedString(payload.shortResult);
        if (shortResult) {
            const label = trimmedString(payload.test);
            return stripLeadingLabel(shortResult, label) || shortResult;
        }

        return trimmedString(payload.status) || null;
    }

    function extractTracebackText(value) {
        if (!value) return null;
        if (typeof value === 'object' && !Array.isArray(value)) {
            return trimmedString(value.traceback) || null;
        }

        const text = trimmedString(value);
        if (!text) return null;
        const parsed = parseStructuredPayload(text);
        if (parsed) {
            const traceback = extractTracebackText(parsed);
            if (traceback) return traceback;
        }
        const marker = text.indexOf('Traceback (most recent call last):');
        return marker >= 0 ? text.slice(marker).trim() : null;
    }

    function parseStructuredPayload(text) {
        const trimmed = trimmedString(text);
        if (!trimmed) return null;

        const candidates = [trimmed];
        const stdoutMatch = trimmed.match(/(?:^|\n)stdout:\n([\s\S]*?)(?:\n\nstderr:\n|$)/);
        if (stdoutMatch && stdoutMatch[1]) candidates.unshift(stdoutMatch[1].trim());
        const stderrMatch = trimmed.match(/(?:^|\n)stderr:\n([\s\S]*)$/);
        if (stderrMatch && stderrMatch[1]) candidates.push(stderrMatch[1].trim());

        for (const candidate of candidates) {
            try {
                return JSON.parse(candidate);
            } catch (_) {
                // Try the next shape.
            }
        }
        return null;
    }

    function stripLeadingLabel(text, label) {
        const trimmedText = trimmedString(text);
        const trimmedLabel = trimmedString(label);
        if (!trimmedText || !trimmedLabel) return null;
        const prefix = `${trimmedLabel}: `;
        return trimmedText.startsWith(prefix) ? trimmedText.slice(prefix.length).trim() : null;
    }

    function trimmedString(value) {
        return typeof value === 'string' ? value.trim() : '';
    }

    function defaultShortResult(status) {
        if (status === 'pass') return 'passed';
        if (status === 'fail') return 'failed';
        if (status === 'timeout') return 'timed out';
        return 'error';
    }

    var api = {
        probeIframeReadiness: probeIframeReadiness,
        kernelFailureEvidence: kernelFailureEvidence,
        kernelLivenessReady: kernelLivenessReady,
        planKernelFailureResponse: planKernelFailureResponse,
        shouldForceReseed: shouldForceReseed,
        reseedPlan: reseedPlan,
        buildOutcomeDisplayNameMap: buildOutcomeDisplayNameMap,
        bestOutcomeDisplayName: bestOutcomeDisplayName,
        formattedOutcomeShortResult: formattedOutcomeShortResult,
        formattedOutcomeDetailedOutput: formattedOutcomeDetailedOutput,
        structuredSummaryText: structuredSummaryText,
        extractTracebackText: extractTracebackText,
        parseStructuredPayload: parseStructuredPayload
    };

    var root = typeof window !== 'undefined' ? window : globalThis;
    root.ChickadeeNotebookCore = api;
    // Node export for the .mjs unit tests.
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    }
}());
