// Public/notebook.js
//
// Chickadee notebook submission page.
//
// Loads the assignment notebook, lets the student edit it in JupyterLite,
// then on "Submit" either:
//   - gradingMode="browser": runs tests locally via window.BrowserRunner
//     (browser-runner.js) and displays results inline, or
//   - gradingMode="worker": sends the notebook to the server and redirects
//     to the submission detail page once the native runner completes.
//
// "Upload & submit": if a file picker is present, uploaded notebook files are
// submitted directly to the native runner (no browser-side grading).

(function () {
    'use strict';

    const frame      = document.getElementById('jl-frame');
    const statusEl   = document.getElementById('nb-status');
    const submitBtn  = document.getElementById('nb-submit');
    const resultsEl  = document.getElementById('nb-results');
    const uploadFile = document.getElementById('nb-upload-file');
    const setupID     = frame ? frame.dataset.setupId : null;
    const gradingMode = frame ? frame.dataset.gradingMode : null;
    // Closed-assignment read-only mode.  Plumbed from the server via
    // NotebookContext.isClosed → notebook.leaf data-read-only.  Disables
    // editing, run shortcuts, and the upload fallback handler.  The submit
    // button is also suppressed server-side (showSubmit=false) when closed.
    const readOnly    = frame ? frame.dataset.readOnly === 'true' : false;

    if (!frame || !setupID) return;

    // ≤640px the page hides the editor behind a "larger screen" notice and
    // an inline guard in notebook.leaf aborts the iframe's eager navigation.
    // Don't run the preflight, watchdog, or editor mount for a surface the
    // student can't see; if the viewport grows past the breakpoint
    // (rotation, window resize) reload so the page boots normally.
    const phoneQuery = window.matchMedia ? window.matchMedia('(max-width: 640px)') : null;
    if (phoneQuery && phoneQuery.matches) {
        const onChange = (e) => { if (!e.matches) window.location.reload(); };
        if (phoneQuery.addEventListener) phoneQuery.addEventListener('change', onChange);
        else if (phoneQuery.addListener) phoneQuery.addListener(onChange);
        return;
    }

    // --- Main-thread freeze watchdog ---------------------------------
    // A dedicated worker beacons a `page_unresponsive` diagnostic if the main
    // thread stops sending heartbeats — i.e. the page hard-freezes (a
    // synchronous Pyodide hang with no SharedArrayBuffer / service-worker sync
    // path, which is Chrome's "Page Unresponsive"). The frozen main thread
    // can't report itself; the worker, on its own thread, can. Fully guarded:
    // this telemetry must never affect the editor.
    // Hoisted so the browser-grading submit path can arm/disarm the grading
    // failover (see armGradingFailover / submitBrowserNotebook). null when
    // Workers are unavailable or construction failed — every use is guarded.
    let freezeWorker = null;
    if (typeof Worker !== 'undefined') {
        try {
            freezeWorker = new Worker('/freeze-watchdog-worker.js');
            let freezeCsrf = '';
            try { freezeCsrf = (typeof getCsrfToken === 'function') ? getCsrfToken() : ''; } catch (_) { /* no token */ }
            freezeWorker.postMessage({
                type: 'init',
                beaconUrl: '/api/v1/client-diagnostics',
                setupID: setupID,
                csrfToken: freezeCsrf,
                thresholdMs: 8000,
            });
            const sendFreezeBeat = () => {
                try { freezeWorker.postMessage({ type: 'beat' }); } catch (_) { /* worker gone */ }
            };
            setInterval(sendFreezeBeat, 2000);
            sendFreezeBeat();
            document.addEventListener('visibilitychange', () => {
                try {
                    freezeWorker.postMessage({ type: 'visibility', visible: !document.hidden });
                } catch (_) { /* worker gone */ }
            });
        } catch (_) {
            // No freeze watchdog — never block the editor over telemetry.
            freezeWorker = null;
        }
    }

    // Arm the freeze-watchdog worker to fail this grade over to the server if the
    // main thread freezes mid-run (a synchronous runaway loop in student code).
    // The worker holds the notebook bytes on its own thread, so it can POST the
    // failover even when the main thread is dead — which the main thread cannot.
    function armGradingFailover(testSetupID, notebookString) {
        if (!freezeWorker) return;
        let csrf = '';
        try { csrf = (typeof getCsrfToken === 'function') ? getCsrfToken() : ''; } catch (_) { /* no token */ }
        try {
            freezeWorker.postMessage({
                type: 'grading-armed',
                setupID: testSetupID,
                notebook: notebookString,
                failoverUrl: '/api/v1/submissions/browser-failover',
                csrfToken: csrf,
            });
        } catch (_) { /* worker gone */ }
    }

    function disarmGradingFailover() {
        if (!freezeWorker) return;
        try { freezeWorker.postMessage({ type: 'grading-disarmed' }); } catch (_) { /* worker gone */ }
    }

    // Main-thread failover for a non-freeze browser-grading failure (e.g. Pyodide
    // won't load): enqueue the server-side backstop grade and return its
    // submission id, or null if even the failover POST fails. The freeze case is
    // handled by the worker above; this is the path when an exception is actually
    // thrown and the main thread is still alive to react.
    async function postBrowserFailover(testSetupID, notebookString) {
        try {
            const res = await fetch('/api/v1/submissions/browser-failover', {
                method: 'POST',
                credentials: 'same-origin',
                headers: { 'content-type': 'application/json', 'x-csrf-token': getCsrfToken() },
                body: JSON.stringify({ testSetupID: testSetupID, notebook: notebookString }),
            });
            if (!res.ok) return null;
            const json = await res.json();
            return (json && json.submissionID) ? json.submissionID : null;
        } catch (_) {
            return null;
        }
    }

    // Disable Submit until the student's notebook has been synced into the
    // JupyterLite editor. This prevents a race condition where students click
    // Submit before their work is loaded, causing a blank notebook to be
    // submitted (the fallback path reads the starter template instead of
    // their saved cells).
    if (submitBtn) {
        submitBtn.disabled = true;
        submitBtn.title = 'Loading notebook\u2026';
    }
    setStatus('loading', 'Loading notebook\u2026');

    // -------------------------------------------------------------------------
    // 1. Load JupyterLite in the iframe
    // -------------------------------------------------------------------------

    // Point the iframe at the embedded JupyterLite distribution.
    // The server provides a concrete JupyterLite file path via data-editor-url.
    // Fall back to the notebook-focused app only if the attribute is missing.
    const notebookURL = frame.dataset.notebookUrl || `/api/v1/testsetups/${setupID}/assignment`;
    const editorURL = frame.dataset.editorUrl ||
        frame.getAttribute('src') ||
        `/jupyterlite/notebooks/index.html?workspace=${encodeURIComponent(setupID)}-student&reset=&path=assignment.ipynb`;
    const lockedNotebookPath = normalizeJupyterPath(extractPathFromEditorURL(editorURL));
    // Timestamp of a forced editor reset whose navigation has not committed
    // yet (cleared by the iframe load event).  Guards the locked-path
    // enforcement against aborting its own still-loading reset.
    let forcedEditorResetAt = 0;
    let serverSyncInFlight = false;
    let serverSyncComplete = false;
    // True once the JupyterLite editor shell is up (the watchdog's reliable
    // shell-ready signal). The browser-grading submit path waits on this so a
    // submit clicked during a cold boot can't kick off a SECOND Pyodide
    // (browser grading runs its own, separate from the editor kernel) that
    // starves the still-booting kernel — the kernel-unhealthy race.
    let editorReady = false;

    // Capability preflight: gate iframe mounting on the browser actually
    // supporting JupyterLite + Pyodide.  If the preflight module isn't
    // loaded (older cached page, network glitch) fall through to the
    // legacy behaviour of mounting unconditionally.
    const failures = window.ChickadeeNotebookFailures;

    // Editor-page error telemetry: capture uncaught errors / unhandled
    // rejections on THIS (parent) page and report them quietly, without
    // changing the UI.  Errors inside the cross-origin JupyterLite iframe are
    // not visible from here — those surface via the watchdog's kernel-unhealthy
    // path instead.  Resource-load errors (<img>/<script> 404s) don't bubble to
    // a non-capturing window listener, so we only see real script errors.
    if (failures && failures.reportEditorError) {
        window.addEventListener('error', function (e) {
            if (!e || (!e.message && !e.error)) return;
            const err = e.error;
            failures.reportEditorError({
                source:  'onerror',
                message: e.message || (err && err.message) || 'error',
                stack:   err && err.stack
            });
        });
        window.addEventListener('unhandledrejection', function (e) {
            const reason = e && e.reason;
            failures.reportEditorError({
                source:  'unhandledrejection',
                message: (reason && reason.message) || String(reason || 'unhandledrejection'),
                stack:   reason && reason.stack
            });
        });
    }

    const preflightPromise = failures
        ? failures.runPreflight()
        : Promise.resolve({ ok: true, failed: [] });

    preflightPromise.then((result) => {
        if (!result.ok) {
            if (failures) {
                failures.showFailure({
                    kind:         'preflight_fail',
                    failedChecks: result.failed
                });
            }
            // Re-enable Submit so the upload-fallback handler runs.
            if (submitBtn) {
                submitBtn.disabled = false;
                submitBtn.title = '';
            }
            setStatus('error', 'In-browser editor unavailable — upload your notebook below.');
            return;
        }
        mountEditor();
    });

    // ----------------------------------------------------------------
    // Editor delivery hardening (kernel boot)
    // ----------------------------------------------------------------
    //
    // The editor is served cross-origin isolated so the Pyodide kernel runs on
    // SharedArrayBuffer with no service worker
    // (docs/notebook-editor-kernel-boot.md). Two failure modes can still leave
    // the kernel spinning forever; these helpers detect and route around them
    // — and beacon them, so a hung kernel is no longer invisible to the admin
    // diagnostics (it used to be logged only as a successful editor_ready).

    // True when the per-client compat cookie is set (the server then serves the
    // editor NON-isolated; see EditorCompatMode.swift).
    function isEditorCompatMode() {
        try { return document.cookie.indexOf('ck-editor-compat=1') !== -1; }
        catch (_) { return false; }
    }

    // #1 — Remove a stale, now-redundant JupyterLite service worker. The
    // SAB-only architecture disabled the SW manager, but a SW registered by a
    // pre-SAB build stays registered and keeps controlling /jupyterlite/* — it
    // can serve stale/uncontrolled responses that break the kernel boot, and a
    // plain refresh never clears it. Drop any we find (never in compat mode,
    // where the SW IS the intended sync path) and reload once if one was
    // actually controlling this load.
    function cleanupRedundantServiceWorker() {
        if (isEditorCompatMode()) return;
        if (typeof navigator === 'undefined' || !navigator.serviceWorker ||
            !navigator.serviceWorker.getRegistrations) return;
        navigator.serviceWorker.getRegistrations().then(function (regs) {
            var removedControlling = false;
            (regs || []).forEach(function (reg) {
                var scope = (reg && reg.scope) || '';
                if (scope.indexOf('/jupyterlite/') === -1) return;
                if (navigator.serviceWorker.controller) removedControlling = true;
                try { reg.unregister(); } catch (_) { /* best effort */ }
            });
            if (typeof caches !== 'undefined' && caches.delete) {
                try { caches.delete('precache'); } catch (_) { /* best effort */ }
            }
            // A SW only stops controlling already-loaded clients on reload, so
            // if one was controlling we reload once (guarded) for a clean,
            // SW-free boot.
            if (removedControlling && !staleSwReloadUsed()) {
                markStaleSwReloadUsed();
                try { window.location.reload(); } catch (_) { /* nothing else to try */ }
            }
        }).catch(function () { /* best effort */ });
    }

    function staleSwReloadUsed() {
        try { return sessionStorage.getItem('chickadee:sw-cleanup:' + setupID) === '1'; }
        catch (_) { return false; }
    }
    function markStaleSwReloadUsed() {
        try { sessionStorage.setItem('chickadee:sw-cleanup:' + setupID, '1'); }
        catch (_) { /* sessionStorage unavailable — reload simply won't be re-gated */ }
    }

    // #2 — The pyodide-kernel polyfills Atomics.waitAsync with a `data:` worker
    // when the engine lacks it natively; `data:` workers are BLOCKED under COEP
    // require-corp, so a cross-origin-isolated page on such an engine (older
    // Safari / iPadOS) hangs the kernel with no fallback. Detect that exact
    // combination and switch to a non-isolated, service-worker-backed boot.
    function browserNeedsDataWorkerCompat() {
        if (typeof crossOriginIsolated === 'undefined' || !crossOriginIsolated) return false;
        if (typeof Atomics === 'undefined') return false;
        return typeof Atomics.waitAsync !== 'function';
    }

    function compatAlreadyTried() {
        try { return sessionStorage.getItem('chickadee:editor-compat:' + setupID) === '1'; }
        catch (_) { return false; }
    }
    function markCompatTried() {
        try { sessionStorage.setItem('chickadee:editor-compat:' + setupID, '1'); }
        catch (_) { /* sessionStorage unavailable */ }
    }

    // Returns true if it kicked off a compat switch (a reload), so the caller
    // stops the normal isolated mount.
    function maybeEnterDataWorkerCompat() {
        if (isEditorCompatMode()) return false;        // already non-isolated
        if (!browserNeedsDataWorkerCompat()) return false;
        if (compatAlreadyTried()) return false;        // never loop
        markCompatTried();
        try {
            document.cookie = 'ck-editor-compat=1; path=/; max-age=86400; SameSite=Lax';
        } catch (_) { /* cookies blocked — fall through; boot-timeout will catch it */ }
        setStatus('loading', 'Preparing the notebook for your browser…');
        try { window.location.reload(); return true; }
        catch (_) { return false; }
    }

    // In compat (non-isolated) mode the SAB sync path is unavailable, so the
    // kernel needs the JupyterLite service worker. The SW manager is disabled,
    // so register it ourselves and wait for it to control /jupyterlite/ before
    // the iframe mounts. Best-effort: on failure the boot-timeout path routes
    // the student to the runner.
    function ensureCompatServiceWorker() {
        if (!isEditorCompatMode()) return Promise.resolve();
        if (typeof navigator === 'undefined' || !navigator.serviceWorker) return Promise.resolve();
        try {
            return navigator.serviceWorker
                .register('/jupyterlite/service-worker.js', { scope: '/jupyterlite/' })
                .then(function () { return whenServiceWorkerActive(5000); })
                .catch(function () { /* best effort */ });
        } catch (_) {
            return Promise.resolve();
        }
    }

    // Isolation/engine context appended to kernel beacons so the admin
    // diagnostics can tell WHY a kernel hung: coi=false → isolation not
    // delivered (e.g. stale SW); waitasync=false under coi=true → the
    // data:-worker block; compat=true → already on the service-worker fallback.
    function isolationBeaconSuffix() {
        var coi = (typeof crossOriginIsolated !== 'undefined') ? !!crossOriginIsolated : false;
        var wa  = (typeof Atomics !== 'undefined' && typeof Atomics.waitAsync === 'function');
        return 'coi=' + coi + ';waitasync=' + wa + ';compat=' + isEditorCompatMode();
    }

    // The kernel reached idle/busy — the success NUMERATOR (paired with
    // editor_ready, the shell denominator).
    function reportKernelReady(elapsedMs) {
        if (failures && failures.reportEvent) {
            failures.reportEvent({
                kind: 'kernel_ready',
                message: 'elapsed_ms=' + Math.round(elapsedMs) + ';' + isolationBeaconSuffix()
            });
        }
    }

    // The kernel never reached ready within the observation window. Beacon it
    // (so the hang is finally visible) and surface the runner path — but do NOT
    // tear down the iframe: it may merely be slow, and hiding it would kill a
    // still-loading kernel.
    function reportKernelBootTimeout() {
        setStatus('error',
            'The Python kernel is taking unusually long to start. You can keep ' +
            'waiting, or click Submit to grade your work on the server.');
        reenableSubmit();
        if (failures && failures.reportEvent) {
            failures.reportEvent({
                kind: 'watchdog_timeout',
                failedChecks: ['kernel-boot-timeout'],
                source: 'kernel',
                message: isolationBeaconSuffix()
            });
        }
    }

    function mountEditor() {
        // #1: drop any stale, redundant JupyterLite service worker before
        // booting (no-op in compat mode, where the SW is the intended path).
        cleanupRedundantServiceWorker();

        // #2: engines that would hit the COEP data:-worker block switch to a
        // non-isolated, service-worker-backed boot (this reloads).
        if (maybeEnterDataWorkerCompat()) return;

        // The template renders the same URL into the iframe's src, so the
        // editor is already loading by the time the preflight resolves.
        // Re-assigning src aborts that in-flight navigation and starts it
        // over — only navigate when the attribute is missing or different
        // (an older cached copy of the page). In compat mode we deliberately
        // (re)mount AFTER the service worker is controlling /jupyterlite/.
        var mountFrame = function () {
            if (frame.getAttribute('src') !== editorURL) {
                frame.src = editorURL;
            }
            scheduleServiceWorkerStateBeacon();
        };
        if (isEditorCompatMode()) {
            ensureCompatServiceWorker().then(mountFrame);
        } else {
            mountFrame();
        }

        // Quick reachability check helps explain blank/failed editor loads.
        fetch(notebookURL, { method: 'GET' }).then((res) => {
            if (!res.ok) {
                setStatus('error', `Notebook source unavailable (${res.status})`);
            }
        }).catch(() => {
            setStatus('error', 'Notebook source unavailable');
        });

        // --- Idle-watchdog activity bridge -------------------------------
        //
        // Keystrokes/clicks INSIDE the JupyterLite iframe never reach the
        // parent window, so idle-logout.js can't see a student who's actively
        // editing.  On each iframe load we attach passive listeners to its
        // document and (a) dispatch `chickadee:activity` on the parent window
        // to reset the client idle deadline, and (b) send a throttled
        // `/session/keepalive` so the server's last_seen_at tracks in-editor
        // work and the next-request gate doesn't expire an active student.
        // Same-origin contentDocument access is reliable in Chromium and
        // best-effort in Safari (hence the try/catch).  Skipped entirely when
        // the idle gate is disabled (timeout meta is 0/absent).
        let lastNotebookKeepalive = 0;

        function idleTimeoutConfigured() {
            const meta = document.querySelector('meta[name="session-idle-timeout-seconds"]');
            return meta ? (parseInt(meta.getAttribute('content'), 10) || 0) > 0 : false;
        }

        function notebookActivity() {
            try {
                window.dispatchEvent(new CustomEvent('chickadee:activity'));
            } catch (_) { /* ignore */ }

            const now = Date.now();
            // Leading-edge, then at most once per 5 minutes.
            if (now - lastNotebookKeepalive < 5 * 60 * 1000) return;
            lastNotebookKeepalive = now;
            const token = ChickadeeUI.getCsrfToken();
            fetch('/session/keepalive', {
                method: 'POST',
                headers: { 'x-csrf-token': token, 'accept': 'application/json' },
                redirect: 'manual'
            }).catch(() => { /* best-effort */ });
        }

        function attachNotebookActivityBridge() {
            if (!idleTimeoutConfigured()) return;
            let doc;
            try { doc = frame.contentDocument; } catch (_) { doc = null; }
            if (!doc || doc._chickadeeActivityBound) return;
            doc._chickadeeActivityBound = true;
            ['keydown', 'pointerdown', 'wheel'].forEach((name) => {
                try {
                    doc.addEventListener(name, notebookActivity, { passive: true, capture: true });
                } catch (_) { /* ignore */ }
            });
        }

        frame.addEventListener('load', () => {
            // A document committed; any forced reset we were waiting on has
            // landed, so the locked-path enforcement may act again.
            forcedEditorResetAt = 0;
            if (!serverSyncComplete && !serverSyncInFlight) {
                void syncNotebookFromServerSnapshot();
            }
            applyLockedNotebookUI();
            enforceLockedNotebookPath();
            attachNotebookActivityBridge();
        });
        setInterval(() => {
            applyLockedNotebookUI();
            enforceLockedNotebookPath();
            attachNotebookActivityBridge();
        }, 1500);

        armEditorWatchdog();
    }

    // Watchdog: two-phase readiness check on the iframe's JupyterLite.
    //
    //   Phase 1 (shell) — wait up to 60s for the JupyterLite UI to appear
    //       in the iframe's DOM.  Failure here means the iframe never
    //       started — fallback fires with kind=watchdog_timeout (no
    //       failedChecks).
    //
    //   Phase 2 (kernel) — once the shell is up, fire ONLY if we see
    //       POSITIVE EVIDENCE the kernel is in a failure state — i.e.
    //       "Kernel Unknown" text in the iframe DOM (Hans's symptom
    //       from PR #467) or a `dead`/`unknown` kernel status reported
    //       via the ServiceManager API.  Absence of positive evidence
    //       of *health* (e.g. the kernel is in "Starting" /
    //       "Connecting" state, or the status text isn't visible to
    //       our probe) is NOT treated as failure.  On the FIRST kernel
    //       failure we reload the editor iframe once (recovery) — a
    //       dead/unknown kernel is usually a transient cold-boot race a
    //       fresh load clears; only a SECOND failure surfaces the upload
    //       fallback + diagnostic.  Phase 2 deadline is a maximum after
    //       which we silently give up watching (we were wrong about a
    //       problem; the page is the user's now).
    //
    // Background: v0.4.149's original probe required positive evidence
    // of kernel health (status text "| Idle" or "| Busy"); v0.4.150 +
    // v0.4.151 didn't fix that.  In production Safari, Pyodide can
    // legitimately take >60s to bootstrap, and the status indicator
    // text doesn't always render the way our probe expects.  We were
    // firing phase-2 timeouts on healthy kernels because we couldn't
    // *prove* they were healthy — which is the wrong contract.
    //
    // Readiness signal: prefer DOM inspection over JS-property access
    // on the iframe's contentWindow.  Same-origin contentWindow access
    // works in Chromium but is unreliable in Safari (cross-process
    // iframe isolation can make `frame.contentWindow.jupyterapp`
    // invisible from the parent even when JupyterLite is fully alive).
    // DOM access is more permissive and matches what the user actually
    // sees on screen.
    //
    // Once the shell is confirmed loaded, `shellLoadedAt` is latched:
    // even if a later poll fails to see the UI (intra-iframe
    // navigation, transient cross-origin error), we don't regress to a
    // phase-1 timeout.
    function armEditorWatchdog() {
        if (!failures) {
            // No preflight/watchdog supervision (legacy cached page): don't
            // gate the submit path on a readiness signal that will never fire.
            markEditorReady();
            return;
        }
        let startedAt            = Date.now();
        const shellDeadline      = 60000;
        const kernelMaxObserveMs = 120000;
        let shellLoadedAt = null;
        let cancelled     = false;
        // One-shot automatic recovery: a kernel that registers `dead` /
        // `unknown` is almost always a transient cold-boot hiccup
        // (WASM/IndexedDB/service-worker race) that a fresh editor load
        // clears.  We reload the iframe ONCE before falling back to the
        // upload panel.  `recovering` suppresses status noise while the
        // reloaded shell comes back up.
        let kernelRecoveryAttempted = false;
        let recovering              = false;
        // The positive kernel-ready beacon is emitted at most once.
        let kernelReadyReported     = false;

        function tick() {
            if (cancelled) return;

            const probe = probeIframeReadiness(frame);
            if (probe.shellReady && shellLoadedAt === null) {
                shellLoadedAt = Date.now();
                // Editor shell is up. Unblock the browser-grading submit path
                // (it waits on this so it won't race a second Pyodide against
                // the kernel's cold boot).
                markEditorReady();
                if (recovering) {
                    // The post-recovery editor is back; clear the transient
                    // "reloading" status and let the student carry on.
                    recovering = false;
                    setStatus('', '');
                    reenableSubmit();
                }
            }

            // Phase 1: shell never seen
            if (shellLoadedAt === null) {
                if (Date.now() - startedAt >= shellDeadline) {
                    cancelled = true;
                    failures.showFailure({ kind: 'watchdog_timeout' });
                    reenableSubmit();
                    return;
                }
                setTimeout(tick, 500);
                return;
            }

            // Positive kernel-ready: the kernel (not just the shell) reached
            // idle/busy. This is the success numerator AND the signal that
            // distinguishes a healthy boot from a hung one — once seen, stop.
            if (probe.kernelReady && !kernelReadyReported) {
                kernelReadyReported = true;
                reportKernelReady(Date.now() - startedAt);
                cancelled = true;
                return;
            }

            // Shell loaded.  Phase 2 fires ONLY on positive evidence the
            // kernel has hit a known failure state.  We escalate through two
            // reload rungs (iframe, then whole page) before surfacing the
            // fallback UI + diagnostic — see planKernelFailureResponse.  Every
            // reload first waits for the service worker to settle, so we don't
            // just re-create the SW-control race that caused the failure.
            if (probe.kernelInFailureState) {
                const plan = planKernelFailureResponse({
                    iframeReloadAttempted: kernelRecoveryAttempted,
                    pageReloadAttempted:   kernelPageReloadUsed(),
                    evidence:              probe.kernelEvidence
                });
                if (plan.action === 'reload-iframe') {
                    kernelRecoveryAttempted = true;
                    recovering = true;
                    setStatus('loading',
                        'The notebook kernel didn’t start — reloading the editor…');
                    // Reload from the parent side (cross-origin-safe; the same
                    // mechanism the locked-path reset uses).  JupyterLite's
                    // workspace restore re-opens the student's saved copy from
                    // IndexedDB on boot and the reseed preservation logic keeps
                    // their work, so this reboots the kernel without discarding
                    // edits.  `forcedEditorResetAt` keeps the locked-path
                    // enforcer from fighting our navigation.  Wait for the SW to
                    // settle first so the fresh boot doesn't re-race it.
                    forcedEditorResetAt = Date.now();
                    whenServiceWorkerActive(5000).then(() => {
                        if (cancelled) return;
                        try { frame.src = editorURL; } catch (_) { /* retry on next tick */ }
                        // Re-arm both phases for the fresh boot.
                        startedAt     = Date.now();
                        shellLoadedAt = null;
                        setTimeout(tick, 2000);
                    });
                    return;
                }
                if (plan.action === 'reload-page') {
                    // The iframe reload re-raced; a full-tab reload is the only
                    // thing that re-bootstraps the SW→client control from
                    // scratch.  Done at most once per tab session (guarded) so
                    // it can never loop.  Stop this watchdog; the reloaded page
                    // arms a fresh one.
                    markKernelPageReloadUsed();
                    recovering = true;
                    cancelled  = true;
                    setStatus('loading',
                        'The notebook kernel didn’t start — reloading the page…');
                    whenServiceWorkerActive(5000).then(() => {
                        try { window.location.reload(); } catch (_) { /* nothing else to try */ }
                    });
                    return;
                }
                cancelled = true;
                failures.showFailure(plan.diagnostic);
                reenableSubmit();
                return;
            }

            // Shell up, but we never saw the kernel reach idle/busy AND never
            // saw positive failure evidence. We used to silently assume healthy
            // here — which made a kernel that spins forever (e.g. the COEP
            // data:-worker block) completely invisible (logged only as a
            // successful editor_ready). Now we beacon it and surface the runner
            // path, without tearing down the iframe in case it is merely slow.
            if (Date.now() - shellLoadedAt >= kernelMaxObserveMs) {
                cancelled = true;
                if (!kernelReadyReported) reportKernelBootTimeout();
                return;
            }
            setTimeout(tick, 1000);
        }
        // First poll after 1s — the shell is never up before that.
        setTimeout(tick, 1000);
    }

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

    function reenableSubmit() {
        if (submitBtn) {
            submitBtn.disabled = false;
            submitBtn.title = '';
        }
    }

    // Editor-readiness gate for the browser-grading submit path (see the
    // `editorReady` declaration). Idempotent; the watchdog flips it on the
    // editor shell's first appearance. Deliberately does NOT enable Submit —
    // that stays gated on the notebook sync so a blank notebook can't be
    // submitted before the student's work loads.
    function markEditorReady() {
        if (editorReady) return;
        editorReady = true;
        // Success denominator: the editor shell came up. Paired with the failure
        // beacons (preflight_fail / watchdog_timeout / page_unresponsive) this
        // lets us compute an editor success RATE, not just count failures.
        if (failures && failures.reportEvent) {
            failures.reportEvent({
                kind: 'editor_ready',
                message: 'elapsed_ms=' + Math.round(performance.now())
            });
        }
    }

    // Reports the editor's sync-path state a few seconds after mount, so the
    // admin browser-diagnostics breakdown can confirm — per browser/device
    // class — that the cross-origin-isolation / SharedArrayBuffer path is
    // actually live, and correlate any "Kernel Unknown" failure with it:
    //
    //   coi=<bool>  — crossOriginIsolated: the page is cross-origin isolated, so
    //                 the kernel can use SharedArrayBuffer for synchronous
    //                 stdin/Drive (the fix for the SW-control race). The signal
    //                 to watch on a new deploy: coi should be true on every
    //                 browser; any browser reporting coi=false (or kernel-
    //                 unhealthy WITH coi=true — e.g. Safari's data:-worker
    //                 polyfill blocked under COEP) is the one to investigate.
    //   sab=<bool>  — SharedArrayBuffer constructor present (should track coi).
    //   registrations=<n> — JupyterLite's service worker still registers; it is
    //                 now a fallback rather than the primary sync path.
    //
    // Fired a few seconds after mount to give the SW manager time to register.
    function scheduleServiceWorkerStateBeacon() {
        setTimeout(function () {
            if (!failures || !failures.reportEvent) return;
            var coi = (typeof crossOriginIsolated !== 'undefined') ? !!crossOriginIsolated : false;
            var sab = (typeof SharedArrayBuffer !== 'undefined');
            var isolation = ';coi=' + coi + ';sab=' + sab;
            if (!('serviceWorker' in navigator)) {
                failures.reportEvent({ kind: 'sw_state', message: 'supported=false' + isolation });
                return;
            }
            navigator.serviceWorker.getRegistrations().then(function (regs) {
                failures.reportEvent({
                    kind: 'sw_state',
                    message: 'supported=true;registrations=' + (regs ? regs.length : 0) + isolation
                });
            }).catch(function () {
                failures.reportEvent({ kind: 'sw_state', message: 'supported=true;error=1' + isolation });
            });
        }, 6000);
    }

    // Resolves once the editor shell is ready, or after `timeoutMs` so a dead
    // editor never blocks submission forever (browser grading still runs in its
    // own Pyodide regardless). Polls because readiness is observed by the
    // watchdog tick. Resolves immediately in the common case (editor long
    // since ready by the time the student clicks Submit).
    function awaitEditorReady(timeoutMs) {
        if (editorReady) return Promise.resolve(true);
        return new Promise((resolve) => {
            const started = Date.now();
            (function poll() {
                if (editorReady) { resolve(true); return; }
                if (Date.now() - started >= timeoutMs) { resolve(false); return; }
                setTimeout(poll, 200);
            })();
        });
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

    // Resolves once the service worker has activated (and ideally is controlling
    // the page), or after `timeoutMs`.  The kernel's sync path is served by the
    // JupyterLite service worker, so reloading *before* the SW has settled just
    // re-creates the "Kernel Unknown" race — waiting first is what turns a
    // re-racing reload into a real recovery.  Best-effort and never rejects: a
    // missing/blocked SW resolves false after the timeout so recovery still
    // proceeds (the reload itself may yet help).  Note the iframe's kernel SW is
    // a different scope from this page, so `controller` here is a proxy for "the
    // SW subsystem has settled", not a guarantee of control — hence the bound.
    function whenServiceWorkerActive(timeoutMs) {
        return new Promise((resolve) => {
            try {
                if (!('serviceWorker' in navigator)) { resolve(false); return; }
                if (navigator.serviceWorker.controller) { resolve(true); return; }
                let settled = false;
                const finish = (value) => {
                    if (settled) return;
                    settled = true;
                    try {
                        navigator.serviceWorker.removeEventListener('controllerchange', onController);
                    } catch (_) { /* ignore */ }
                    resolve(value);
                };
                const onController = () => finish(true);
                try {
                    navigator.serviceWorker.addEventListener('controllerchange', onController);
                } catch (_) { /* ignore */ }
                navigator.serviceWorker.ready.then(() => {
                    if (navigator.serviceWorker.controller) finish(true);
                }).catch(() => { /* fall through to timeout */ });
                setTimeout(() => {
                    finish(!!(navigator.serviceWorker && navigator.serviceWorker.controller));
                }, timeoutMs);
            } catch (_) {
                resolve(false);
            }
        });
    }

    // One full-page reload per (tab session, setup): the flag survives the
    // reload (sessionStorage is per-tab), so the escalation ladder can't loop
    // into a reload storm.  A fresh tab starts with a clean flag, so a later
    // genuine retry still gets the full ladder.
    function kernelPageReloadStorageKey() {
        return 'chickadee:kernel-page-reload:' + setupID;
    }
    function kernelPageReloadUsed() {
        try { return sessionStorage.getItem(kernelPageReloadStorageKey()) === '1'; }
        catch (_) { return false; }
    }
    function markKernelPageReloadUsed() {
        try { sessionStorage.setItem(kernelPageReloadStorageKey(), '1'); }
        catch (_) { /* sessionStorage unavailable — page reload simply won't be re-gated */ }
    }

    // Hard fallback: if the notebook hasn't synced within 15 seconds (e.g. the
    // iframe never loaded) re-enable Submit so the student isn't stuck. The
    // fallback submit path (server snapshot → DOM → contents API) will still
    // attempt to find their work.
    setTimeout(() => {
        if (submitBtn && submitBtn.disabled) {
            submitBtn.disabled = false;
            submitBtn.title = '';
            if (!serverSyncComplete) setStatus('', '');
        }
    }, 15000);

    // -------------------------------------------------------------------------
    // 2. Submit button — queue runner grading
    // -------------------------------------------------------------------------

    if (submitBtn) {
        submitBtn.addEventListener('click', async () => {
            submitBtn.disabled = true;
            clearResults();
            setStatus('loading', 'Preparing submission…');

            try {
                setStatus('loading', 'Capturing notebook…');
                const notebook = await loadNotebookForSubmit();

                if (gradingMode === 'browser') {
                    if (!window.BrowserRunner || typeof window.BrowserRunner.runAndSubmit !== 'function') {
                        throw new Error('Browser grading is unavailable right now. Please reload and try again.');
                    }
                    // Browser grading runs its own Pyodide, separate from the
                    // editor kernel. Don't start it while the kernel is still
                    // cold-booting — that contention is what leaves the kernel
                    // dead/unknown. Wait for the editor shell first; resolves
                    // immediately once ready (the common case) and is bounded so
                    // a genuinely dead editor still degrades to grading here.
                    if (!editorReady) {
                        setStatus('loading', 'Waiting for the editor to finish loading…');
                        await awaitEditorReady(45000);
                    }
                    // Browser-graded lab: run tests locally in Pyodide then submit atomically.
                    const { outcomes } = await submitBrowserNotebook(notebook, setupID);
                    const passCount = outcomes.filter(o => o.status === 'pass').length;
                    const allPassed = passCount === outcomes.length && outcomes.length > 0;
                    const summary   = `${passCount} / ${outcomes.length} passed` +
                                      (allPassed ? ' ✓ All tests passed!' : '');
                    setStatus('ok', summary);
                    return;
                }

                // Worker-graded assignment: enqueue for native runner.
                setStatus('loading', 'Submitting…');
                const response = await postRunnerSubmission(notebook, setupID);
                setStatus('loading', 'Submission queued. Opening grade details…');
                window.location.assign(`/submissions/${response.submissionID}`);
                return;
            } catch (err) {
                const msg = (err instanceof Error && err.message)
                    ? err.message
                    : String(err);
                console.error('[notebook] Submit error:', err);
                setStatus('error', `Error: ${msg}`);
            } finally {
                submitBtn.disabled = false;
            }
        });
    }

    async function loadNotebookForSubmit() {
        const liveNotebook = await readNotebookFromJupyterFrame();
        if (liveNotebook) return liveNotebook;

        const snapshotNotebook = await fetchNotebookSnapshot();
        const domNotebook = readNotebookFromVisibleDOM(snapshotNotebook);
        if (domNotebook) return domNotebook;

        const pathFromURL = lockedNotebookPath || extractPathFromEditorURL(editorURL);
        const apiNotebook = await readNotebookViaContentsAPI(pathFromURL);
        if (apiNotebook) return apiNotebook;

        if (snapshotNotebook) return snapshotNotebook;
        throw new Error('Failed to capture notebook contents');
    }

    async function fetchNotebookSnapshot() {
        const nbRes = await fetch(notebookURL);
        if (!nbRes.ok) return null;
        const notebook = await nbRes.json();
        return looksLikeNotebook(notebook) ? notebook : null;
    }

    // Exposed for idle-logout.js: flush the open notebook to JupyterLite's
    // storage before the inactivity watchdog signs the user out, so unsaved
    // cells survive. Best-effort and read-only-aware; never throws.
    window.chickadeeSaveNotebook = async function () {
        if (readOnly) return;
        try {
            const childWindow = frame.contentWindow;
            const app = childWindow && childWindow.jupyterapp;
            if (app && app.commands && typeof app.commands.execute === 'function') {
                try { await app.commands.execute('docmanager:save'); } catch (_) {}
                try { await app.commands.execute('docmanager:save-all'); } catch (_) {}
                await delay(150);
            }
        } catch (_) {
            // Saving is best-effort; swallow everything.
        }
    };

    async function readNotebookFromJupyterFrame() {
        try {
            const childWindow = frame.contentWindow;
            const app = childWindow && childWindow.jupyterapp;
            if (!app || !app.shell) return null;

            // Best effort: flush edits to the notebook model/context before reading.
            if (app.commands && typeof app.commands.execute === 'function') {
                try { await app.commands.execute('docmanager:save'); } catch (_) {}
                try { await app.commands.execute('docmanager:save-all'); } catch (_) {}
            }
            // Allow save handlers to settle before reading back from contents.
            await delay(125);

            const widget = notebookWidgetFromShell(app.shell, lockedNotebookPath);
            const modelNotebook = notebookFromWidget(widget);
            if (modelNotebook) return modelNotebook;

            const pathFromWidget = normalizeJupyterPath(widget && widget.context && widget.context.path);
            const pathFromURL = lockedNotebookPath || normalizeJupyterPath(extractPathFromEditorURL(editorURL));
            const notebookPath = pathFromWidget || pathFromURL;

            const contents = app.serviceManager && app.serviceManager.contents;
            if (!contents || typeof contents.get !== 'function' || !notebookPath) return null;

            const contentModel = await contents.get(notebookPath, { content: true, format: 'json' });
            const contentNotebook = contentModel && contentModel.content;
            if (looksLikeNotebook(contentNotebook)) {
                return toPlainNotebook(contentNotebook);
            }
        } catch (_) {
            // Fall back to server-provided notebook URL below.
        }
        return null;
    }

    function notebookWidgetFromShell(shell, preferredPath) {
        if (!shell) return null;
        const preferred = normalizeJupyterPath(preferredPath);
        let firstNotebook = null;
        const pathLooksNotebook = (path) => !!path && path.toLowerCase().endsWith('.ipynb');

        try {
            if (typeof shell.widgets === 'function') {
                const widgets = shell.widgets('main');
                for (const widget of widgets) {
                    const path = normalizeJupyterPath(widget && widget.context && widget.context.path);
                    const modelNotebook = notebookFromWidget(widget);
                    const isNotebookWidget = pathLooksNotebook(path) || !!modelNotebook;
                    if (!isNotebookWidget) continue;
                    if (!firstNotebook) firstNotebook = widget;
                    if (preferred && path === preferred) return widget;
                }
            }
        } catch (_) {
            // Ignore shell traversal errors.
        }

        const current = shell.currentWidget || null;
        const currentPath = normalizeJupyterPath(current && current.context && current.context.path);
        const currentNotebook = notebookFromWidget(current);
        if (pathLooksNotebook(currentPath) || currentNotebook) {
            return current;
        }
        return firstNotebook;
    }

    function notebookFromWidget(widget) {
        if (!widget) return null;

        const candidates = [
            widget.content && widget.content.model,
            widget.context && widget.context.model,
            widget.model
        ];

        for (const candidate of candidates) {
            if (!candidate || typeof candidate.toJSON !== 'function') continue;
            try {
                const notebook = candidate.toJSON();
                if (looksLikeNotebook(notebook)) return toPlainNotebook(notebook);
            } catch (_) {
                // Try next candidate.
            }
        }
        return null;
    }

    function extractPathFromEditorURL(url) {
        try {
            const parsed = new URL(url, window.location.origin);
            return parsed.searchParams.get('path');
        } catch (_) {
            return null;
        }
    }

    function normalizeJupyterPath(path) {
        if (!path) return '';
        return String(path).replace(/^\/+/, '').trim();
    }

    function readNotebookFromVisibleDOM(baseNotebook) {
        if (!baseNotebook || !looksLikeNotebook(baseNotebook) || !frame.contentDocument) return null;
        try {
            const doc = frame.contentDocument;
            const codeCellNodes = Array.from(doc.querySelectorAll('.jp-CodeCell'));
            if (!codeCellNodes.length) return null;

            const visibleCodeSources = codeCellNodes.map(extractVisibleCodeCellText);
            const notebook = toPlainNotebook(baseNotebook);
            const codeCellIndexes = [];
            for (let i = 0; i < notebook.cells.length; i += 1) {
                const cell = notebook.cells[i];
                if (cell && cell.cell_type === 'code') codeCellIndexes.push(i);
            }
            if (!codeCellIndexes.length || !visibleCodeSources.length) return null;

            const pairCount = Math.min(codeCellIndexes.length, visibleCodeSources.length);
            for (let i = 0; i < pairCount; i += 1) {
                const cellIndex = codeCellIndexes[i];
                notebook.cells[cellIndex].source = sourceArrayFromText(visibleCodeSources[i]);
            }

            for (let i = codeCellIndexes.length; i < visibleCodeSources.length; i += 1) {
                notebook.cells.push({
                    cell_type: 'code',
                    execution_count: null,
                    metadata: {},
                    outputs: [],
                    source: sourceArrayFromText(visibleCodeSources[i])
                });
            }
            return notebook;
        } catch (_) {
            return null;
        }
    }

    function extractVisibleCodeCellText(cellNode) {
        if (!cellNode) return '';
        const lineNodes = Array.from(cellNode.querySelectorAll('.cm-content .cm-line'));
        if (!lineNodes.length) return '';
        return lineNodes
            .map(node => normalizeEditorText(node.textContent || ''))
            .join('\n');
    }

    function normalizeEditorText(text) {
        return String(text)
            .replace(/\u200b/g, '')
            .replace(/\r\n/g, '\n');
    }

    function sourceArrayFromText(text) {
        const normalized = normalizeEditorText(text);
        if (!normalized.length) return [];
        const lines = normalized.split('\n');
        return lines.map((line, idx) => (idx < lines.length - 1 ? `${line}\n` : line));
    }

    function enforceLockedNotebookPath() {
        if (!lockedNotebookPath || !frame.contentWindow) return;
        try {
            const rawHref = frame.contentWindow.location.href;

            // Until the iframe commits its first document, location.href is
            // still the initial "about:blank" — the editor is loading, not
            // navigated away.  Resetting src in that state aborts the
            // in-flight load; on a slow connection (or a server busy with a
            // class-wide rush) each 1.5s tick would abort and restart the
            // navigation forever, so a healthy-but-slow boot never commits
            // and the shell watchdog misfires.  Wait for a real document.
            if (rawHref === 'about:blank') return;

            const currentURL = new URL(rawHref, window.location.origin);
            const currentPath = normalizeJupyterPath(currentURL.searchParams.get('path'));
            const inNotebookApp = currentURL.pathname.includes('/jupyterlite/notebooks/');

            if (inNotebookApp && currentPath === lockedNotebookPath) return;

            // The previous document's URL stays current while a forced
            // reset's navigation is in flight, so the path still reads as
            // wrong here.  Give the reset a generous window to commit (the
            // load event clears the stamp) before forcing another one,
            // otherwise slow recoveries are aborted in the same loop.
            const now = Date.now();
            if (forcedEditorResetAt && now - forcedEditorResetAt < 20000) return;
            forcedEditorResetAt = now;
            frame.src = editorURL;
        } catch (_) {
            // Ignore transient cross-frame navigation states.
        }
    }

    async function syncNotebookFromServerSnapshot() {
        if (!lockedNotebookPath || serverSyncInFlight || serverSyncComplete) return;
        serverSyncInFlight = true;
        try {
            const snapshotRes = await fetch(notebookURL, { method: 'GET' });
            if (!snapshotRes.ok) return;
            const snapshotNotebook = await snapshotRes.json();
            if (!looksLikeNotebook(snapshotNotebook)) return;

            const app = await waitForJupyterApp(8000);
            if (!app) return;

            const contents = app.serviceManager && app.serviceManager.contents;

            // Server-side overwrite detection.  The server stamps the iframe
            // with `data-working-copy-mtime` = the Unix-epoch mtime of the
            // working-copy file on disk.  We persist the last mtime this
            // browser has *seen* (per setup) in localStorage.  When the
            // server mtime is newer than the saved baseline, the server
            // overwrote the file since our last visit — usually because an
            // instructor clicked "Reset notebook" — and we must NOT
            // preserve the local IndexedDB copy: we force-overwrite it
            // with the server snapshot so the reset is visible without a
            // manual cache-clear.
            //
            // CRITICAL SAFETY: a missing localStorage entry (`seenMtime`
            // === 0) is treated as "no baseline" — NOT as "any server
            // mtime is newer."  Otherwise the very first visit AFTER this
            // code is deployed would wipe every student's in-progress
            // IndexedDB work because `localStorage` doesn't have the new
            // key yet but the working-copy file already has a non-zero
            // mtime.  The baseline gets stamped at the end of this
            // function so the *second* post-deploy visit has something to
            // compare against, and only resets that bump the mtime after
            // that baseline are treated as force-reseed events.
            const serverMtime = parseInt(frame.dataset.workingCopyMtime || '0', 10) || 0;
            const seenKey = 'chickadee_nb_mtime_' + setupID;
            let seenMtime = 0;
            try { seenMtime = parseInt(localStorage.getItem(seenKey) || '0', 10) || 0; } catch (_) {}
            const serverIsNewer = shouldForceReseed({ serverMtime, seenMtime });

            // Preservation logic: if the browser already has the notebook in
            // IndexedDB AND the server hasn't overwritten it since we last
            // saw it, keep the local version — that's the student's
            // in-progress work.  Otherwise (no local copy, OR server is
            // newer than our baseline) seed from the server.
            let hasLocalContent = false;
            if (contents && typeof contents.get === 'function') {
                try {
                    const localModel = await contents.get(lockedNotebookPath, { content: true });
                    hasLocalContent = looksLikeNotebook(localModel && localModel.content);
                } catch (_) {
                    // Not found in local storage — will seed from server below.
                }
            }

            const plan = reseedPlan({ hasLocalContent, serverIsNewer });
            if (plan.shouldSeed && contents && typeof contents.save === 'function') {
                await contents.save(lockedNotebookPath, {
                    type: 'notebook',
                    format: 'json',
                    content: snapshotNotebook
                });
            }

            // Stamp the mtime we just synced from so subsequent visits know
            // what we've already seen.  Skip if localStorage is unavailable
            // (private mode etc.) — the preservation logic still works on
            // hasLocalContent alone in that case.
            if (serverMtime > 0) {
                try { localStorage.setItem(seenKey, String(serverMtime)); } catch (_) {}
            }

            if (app.commands && typeof app.commands.execute === 'function') {
                try {
                    const widget = await app.commands.execute(
                        'docmanager:open', { path: lockedNotebookPath });
                    // CRITICAL for instructor/self "Reset notebook": when the
                    // server overwrote the working copy since we last saw it,
                    // JupyterLite's workspace restore has typically already
                    // re-opened the *previous* (stale) document from IndexedDB
                    // before our reseed above committed.  `docmanager:open` on
                    // an already-open path only focuses that widget — it does
                    // NOT re-read the freshly-seeded contents — so without this
                    // the reset only becomes visible on a *second* page load
                    // (the student/TA sees "nothing happened").  Reverting the
                    // document context forces it to reload from the contents we
                    // just wrote, so the reset is visible immediately.  Gated on
                    // `reloadOpenDoc` (server-newer only) so a normal revisit
                    // never discards the student's unsaved in-editor edits.
                    if (plan.reloadOpenDoc && widget && widget.context
                        && typeof widget.context.revert === 'function') {
                        await widget.context.revert();
                    }
                } catch (_) {
                    // Best-effort open only.
                }
            }

            serverSyncComplete = true;
        } catch (_) {
            // Retry on the next load tick if synchronization fails.
        } finally {
            serverSyncInFlight = false;
            // Always re-enable Submit — either the sync loaded the student's
            // saved work, or the fallback submit path will handle it.
            if (submitBtn) {
                submitBtn.disabled = false;
                submitBtn.title = '';
            }
            setStatus('', '');
        }
    }

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

    async function waitForJupyterApp(timeoutMs) {
        const started = Date.now();
        while (Date.now() - started < timeoutMs) {
            const app = frame.contentWindow && frame.contentWindow.jupyterapp;
            const contents = app && app.serviceManager && app.serviceManager.contents;
            if (app && contents) return app;
            await delay(100);
        }
        return null;
    }

    function applyLockedNotebookUI() {
        if (!frame.contentDocument) return;
        const doc = frame.contentDocument;
        if (!doc.getElementById('chickadee-notebook-lock-style')) {
            const rules = [
                '.jp-SideBar, .jp-SidePanel, .jp-FileBrowser, .jp-FileBrowser-Panel, .jp-DirListing { display: none !important; }',
                '.lm-MenuBar, .jp-MenuBar, .jp-TopBar { display: none !important; }'
            ];
            if (readOnly) {
                rules.push(
                    '.jp-Toolbar, .jp-Cell .jp-Toolbar, .jp-CellHeader, .jp-CellFooter { display: none !important; }',
                    '.cm-content { caret-color: transparent !important; }'
                );
            }
            const style = doc.createElement('style');
            style.id = 'chickadee-notebook-lock-style';
            style.textContent = rules.join('\n');
            doc.head.appendChild(style);
        }

        if (readOnly) {
            doc.querySelectorAll('.cm-content').forEach((el) => {
                if (el.getAttribute('contenteditable') !== 'false') {
                    el.setAttribute('contenteditable', 'false');
                }
            });
            if (!doc.__chickadeeReadOnlyKeyHandler) {
                const handler = (event) => {
                    if (event.key !== 'Enter') return;
                    if (event.shiftKey || event.ctrlKey || event.metaKey || event.altKey) {
                        event.preventDefault();
                        event.stopPropagation();
                    }
                };
                doc.addEventListener('keydown', handler, true);
                doc.__chickadeeReadOnlyKeyHandler = handler;
            }
        }
    }

    function looksLikeNotebook(value) {
        return !!value && typeof value === 'object' && Array.isArray(value.cells);
    }

    function toPlainNotebook(notebook) {
        try {
            return JSON.parse(JSON.stringify(notebook));
        } catch (_) {
            return notebook;
        }
    }

    async function readNotebookViaContentsAPI(path) {
        if (!path) return null;
        const encodedPath = path.split('/').map(encodeURIComponent).join('/');
        const candidates = [
            `/jupyterlite/api/contents/${encodedPath}?content=1`,
            `/jupyterlite/lab/api/contents/${encodedPath}?content=1`,
            `/jupyterlite/notebooks/api/contents/${encodedPath}?content=1`,
            `/notebooks/api/contents/${encodedPath}?content=1`,
            `/api/contents/${encodedPath}?content=1`
        ];

        for (const url of candidates) {
            try {
                const res = await fetch(url);
                if (!res.ok) continue;
                const payload = await res.json();
                if (looksLikeNotebook(payload && payload.content)) {
                    return toPlainNotebook(payload.content);
                }
            } catch (_) {
                // Try the next candidate URL.
            }
        }
        return null;
    }

    // -------------------------------------------------------------------------
    // 3. Upload & submit — read file → queue runner grading
    // -------------------------------------------------------------------------

    if (uploadFile && readOnly) {
        uploadFile.disabled = true;
    }
    if (uploadFile) {
        uploadFile.addEventListener('change', async () => {
            if (readOnly) {
                uploadFile.value = '';
                setStatus('error', 'This assignment is closed — submissions are no longer accepted.');
                return;
            }
            const file = uploadFile.files && uploadFile.files[0];
            if (!file) return;

            if (submitBtn) submitBtn.disabled = true;
            clearResults();
            setStatus('loading', 'Preparing submission…');

            try {
                // Read the student's uploaded notebook.
                const uploadedText     = await readFileAsText(file);
                const uploadedNotebook = JSON.parse(uploadedText);

                if (gradingMode === 'browser') {
                    if (!window.BrowserRunner || typeof window.BrowserRunner.runAndSubmit !== 'function') {
                        throw new Error('Browser grading is unavailable right now. Please reload and try again.');
                    }
                    const { outcomes } = await submitBrowserNotebook(uploadedNotebook, setupID);
                    const passCount = outcomes.filter(o => o.status === 'pass').length;
                    const allPassed = passCount === outcomes.length && outcomes.length > 0;
                    const summary   = `${passCount} / ${outcomes.length} passed` +
                                      (allPassed ? ' ✓ All tests passed!' : '');
                    setStatus('ok', summary);
                    return;
                }

                setStatus('loading', 'Submitting…');
                const response = await postRunnerSubmission(
                    uploadedNotebook,
                    setupID,
                    file.name || 'submission.ipynb'
                );

                setStatus('loading', 'Submission queued. Opening grade details…');
                window.location.assign(`/submissions/${response.submissionID}`);
                return;
            } catch (err) {
                const msg = (err instanceof Error && err.message)
                    ? err.message
                    : String(err);
                console.error('[notebook] Upload error:', err);
                setStatus('error', `Error: ${msg}`);
            } finally {
                if (submitBtn) submitBtn.disabled = false;
                // Reset so the same file can be re-selected.
                uploadFile.value = '';
            }
        });
    }

    // -------------------------------------------------------------------------
    // 8. POST to /api/v1/submissions/runner-submit
    // -------------------------------------------------------------------------

    async function postRunnerSubmission(notebook, testSetupID, filename = 'submission.ipynb') {
        const formData = new FormData();
        formData.append('notebook',    new Blob([JSON.stringify(notebook)], { type: 'application/json' }), 'notebook.ipynb');
        formData.append('testSetupID', testSetupID);
        formData.append('filename', filename);

        const res = await fetch('/api/v1/submissions/runner-submit', {
            method:  'POST',
            headers: { 'x-csrf-token': getCsrfToken() },
            body:    formData,
        });
        if (!res.ok) {
            const text = await res.text();
            throw new Error(`Server error ${res.status}: ${text}`);
        }
        return res.json();
    }

    async function submitBrowserNotebook(notebook, testSetupID) {
        setStatus('loading', 'Testing…');
        const notebookString = JSON.stringify(notebook);
        const notebookBytes = new Uint8Array(new TextEncoder().encode(notebookString));

        // Arm the freeze failover before grading: if the main thread hangs on a
        // runaway loop, the watchdog worker enqueues a server-side grade with
        // these bytes. Disarmed below the moment grading resolves either way.
        armGradingFailover(testSetupID, notebookString);

        let result;
        try {
            result = await window.BrowserRunner.runAndSubmit(notebookBytes, testSetupID);
        } catch (err) {
            disarmGradingFailover();
            // Browser grading failed outright (not a freeze — the watchdog covers
            // those). Fall back to server-side grading so the student's work is
            // still graded instead of leaving them with only an error.
            const failoverID = await postBrowserFailover(testSetupID, notebookString);
            if (failoverID) {
                setStatus('loading',
                    'Grading didn’t finish in your browser — we’ve queued it for server grading. Opening grade details…');
                window.location.assign(`/submissions/${failoverID}`);
                // The page is navigating away; stop here so the caller's
                // success-summary code never runs against an empty result.
                return new Promise(() => {});
            }
            throw err;
        }
        disarmGradingFailover();

        const { outcomes, response, sections, sectionIDs } = result;
        renderResults(outcomes, response, sections, sectionIDs);
        return { outcomes, response };
    }

    // -------------------------------------------------------------------------
    // 9. Inline results rendering
    // -------------------------------------------------------------------------

    function clearResults() {
        if (resultsEl) {
            resultsEl.hidden = true;
            resultsEl.innerHTML = '';
        }
    }

    // Pattern that identifies a dependency-skip shortResult.
    const SKIP_RE = /^Skipped: prerequisite '(.+)' did not pass$/;

    function renderResults(outcomes, response, sections, sectionIDs) {
        if (!resultsEl) return;
        const displayNameMap = buildOutcomeDisplayNameMap(outcomes);

        const pass    = outcomes.filter(o => o.status === 'pass').length;
        const fail    = outcomes.filter(o => o.status === 'fail').length;
        const error   = outcomes.filter(o => o.status === 'error').length;
        const timeout = outcomes.filter(o => o.status === 'timeout').length;
        const total   = outcomes.length;

        // Summary line below the status bar
        const summaryEl = document.createElement('p');
        summaryEl.className = 'score';
        const parts = [`${pass} / ${total} passed`];
        if (fail)    parts.push(`${fail} failed`);
        if (error)   parts.push(`${error} error${error > 1 ? 's' : ''}`);
        if (timeout) parts.push(`${timeout} timed out`);
        summaryEl.textContent = parts.join(' · ');

        resultsEl.innerHTML = '';
        resultsEl.appendChild(summaryEl);

        // One table per section, mirroring the server-rendered submission view
        // (submission.leaf).  Unlabelled groups (no sections defined) render as
        // a single bare table, identical to the pre-sections layout.
        for (const group of groupOutcomesForDisplay(outcomes, sections, sectionIDs)) {
            const block = document.createElement('section');
            block.className = 'submission-section-block';
            if (group.sectionName) {
                const heading = document.createElement('h3');
                heading.className = 'submission-section-heading';
                heading.textContent = group.sectionName;
                block.appendChild(heading);
            }
            block.appendChild(buildResultsTable(group.outcomes, displayNameMap));
            resultsEl.appendChild(block);
        }

        resultsEl.hidden = false;

        // Scroll to the first test the student still needs to fix — usually the
        // question they are actively working on — rather than the top of the
        // results.  We target the first failing/error/timeout row, ignoring
        // dependency-skipped rows (those are downstream of an actual failure,
        // which is the better landing spot).  When everything passes there is
        // nothing to fix, so fall back to the top of the results so the student
        // sees the all-green summary.
        const firstUnresolved = resultsEl.querySelector(
            'tr.status-fail, tr.status-error, tr.status-timeout'
        );
        if (firstUnresolved) {
            firstUnresolved.scrollIntoView({ behavior: 'smooth', block: 'center' });
        } else {
            resultsEl.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }
    }

    // Group outcomes for display via the browser runner's shared helper, with a
    // flat single-bucket fallback if it is somehow unavailable.
    function groupOutcomesForDisplay(outcomes, sections, sectionIDs) {
        if (window.BrowserRunner && typeof window.BrowserRunner.groupBySection === 'function') {
            return window.BrowserRunner.groupBySection(outcomes, sections, sectionIDs);
        }
        return [{ sectionName: null, outcomes }];
    }

    // Build one 4-column results table (Test / Tier / Output / Mark) for the
    // given outcomes — the structure matches submission.leaf.
    function buildResultsTable(outcomes, displayNameMap) {
        const table = document.createElement('table');
        table.className = 'results-table';
        table.innerHTML = `
            <thead>
                <tr>
                    <th>Test</th>
                    <th>Tier</th>
                    <th>Output</th>
                    <th>Mark</th>
                </tr>
            </thead>`;

        const tbody = document.createElement('tbody');
        for (const o of outcomes) {
            const skipMatch  = SKIP_RE.exec(o.shortResult || '');
            const isSkipped  = !!skipMatch;
            const blockerRaw = isSkipped ? skipMatch[1] : null;
            // Strip file extension: "test_build.py" → "test_build"
            const blockerKey = blockerRaw
                ? (blockerRaw.includes('.') ? blockerRaw.replace(/\.[^.]+$/, '') : blockerRaw)
                : null;
            const blockerName = blockerKey ? (displayNameMap.get(blockerKey) || blockerKey) : null;
            const displayName = bestOutcomeDisplayName(o);
            const shortResult = formattedOutcomeShortResult(o);
            const longResult = formattedOutcomeDetailedOutput(o);

            const tr = document.createElement('tr');
            tr.className = isSkipped ? 'status-skipped' : `status-${o.status}`;

            // Mark label and CSS class
            let markLabel, markClass;
            if (isSkipped) {
                markLabel = '—';       markClass = 'skipped';
            } else {
                switch (o.status) {
                    case 'pass':    markLabel = 'Pass';    markClass = 'pass';    break;
                    case 'fail':    markLabel = 'Fail';    markClass = 'fail';    break;
                    case 'error':   markLabel = 'Error';   markClass = 'error';   break;
                    case 'timeout': markLabel = 'Timeout'; markClass = 'timeout'; break;
                    default:        markLabel = 'Fail';    markClass = 'fail';
                }
            }

            // Test name cell — with optional "↳ blocked by" annotation for skips
            const blockerHtml = blockerName
                ? `<div class="skip-blocker">↳ blocked by <code>${escHtml(blockerName)}</code></div>`
                : '';

            // Output cell
            let outputHtml;
            if (isSkipped) {
                outputHtml = `<span class="skip-reason">${escHtml(shortResult)}</span>`;
            } else {
                const longHtml = longResult
                    ? `<details><summary>Show output ▸</summary><pre>${escHtml(longResult)}</pre></details>`
                    : '';
                outputHtml = escHtml(shortResult) + longHtml;
            }

            tr.innerHTML = `
                <td><code>${escHtml(displayName)}</code>${blockerHtml}</td>
                <td><span class="tier">${escHtml(o.tier)}</span></td>
                <td>${outputHtml}</td>
                <td><span class="result-mark result-mark-${markClass}">${escHtml(markLabel)}</span></td>`;
            tbody.appendChild(tr);
        }
        table.appendChild(tbody);
        return table;
    }

    // Shared implementation (Public/chickadee-ui.js).  Deliberately a lazy
    // wrapper (not `ChickadeeUI.escapeHtml` directly): the node tests run
    // this file in a vm context without ChickadeeUI, so the global must not
    // be touched at module load time.
    const escHtml = (str) => ChickadeeUI.escapeHtml(str);

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

    // -------------------------------------------------------------------------
    // 10. Helpers
    // -------------------------------------------------------------------------

    function setStatus(type, msg) {
        statusEl.textContent  = msg;
        statusEl.className    = `nb-status${type ? ' nb-status-' + type : ''}`;
    }

    function readFileAsText(file) {
        return new Promise((resolve, reject) => {
            const r   = new FileReader();
            r.onload  = e => resolve(e.target.result);
            r.onerror = () => reject(new Error('Could not read file'));
            r.readAsText(file);
        });
    }

    function delay(ms) {
        return new Promise(resolve => setTimeout(resolve, ms));
    }

    const testHooks = globalThis.__CHICKADEE_NOTEBOOK_TEST_HOOKS__;
    if (testHooks) {
        testHooks.exports = {
            buildOutcomeDisplayNameMap,
            bestOutcomeDisplayName,
            formattedOutcomeShortResult,
            formattedOutcomeDetailedOutput,
            structuredSummaryText,
            extractTracebackText,
            parseStructuredPayload,
            probeIframeReadiness,
            kernelFailureEvidence,
            kernelLivenessReady,
            planKernelFailureResponse,
            shouldForceReseed,
            reseedPlan,
        };
    }
})();
