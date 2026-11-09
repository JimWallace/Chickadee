// @ts-check
// Public/kernel-prewarm.js
//
// Warms the browser's HTTP cache with the kernel files the dashboard's open
// notebook assignments boot, so the first class session does not download
// every student's kernel at once (docs/jupyterlite.md, "What a kernel boot
// downloads"). The script tag carries the lists in `data-kernel-assets`
// (`KernelAssetList`, rendered only when there is something to warm);
// kernel-asset-telemetry.js does the work.
//
// Quiet by construction: it waits for the page to load and go idle, then
// fetches one file at a time at low priority. It skips a data-saving or 2G
// connection and a kernel this browser already warmed at its current
// version. Nothing on the page depends on it: a failure only leaves the cache
// as it was, and the kernel downloads what it needs when it boots, as it
// always has.

(function () {
    'use strict';

    var K = window.ChickadeeKernelAssets;
    var script = /** @type {HTMLScriptElement | null} */ (document.currentScript);
    if (!K || !script) return;

    // Waits this long after idle before the first fetch, so a student who
    // opens a notebook straight from the dashboard is not racing the warm.
    var START_DELAY_MS = 5000;

    var lists = K.parseLists(script.dataset.kernelAssets || '');
    if (!lists.length) return;

    /** @type {Storage | null} */
    var storage = null;
    try { storage = window.localStorage; } catch (_) { storage = null; }

    var connection = /** @type {any} */ (navigator).connection || null;

    async function run() {
        var plan = K.warmPlan(lists, connection, storage);
        for (var i = 0; i < plan.length; i++) {
            var list = plan[i];
            var started = performance.now();
            var ok = false;
            try {
                ok = await K.warmList(list, window.fetch.bind(window), storage);
            } catch (_) {
                ok = false;
            }
            if (!ok) return;
            var entries = [];
            try { entries = performance.getEntriesByType('resource'); } catch (_) { entries = []; }
            K.report('prewarm', K.prewarmMessage(list, entries, performance.now() - started), null);
        }
    }

    function scheduleAfterIdle() {
        var start = function () { setTimeout(function () { run().catch(function () { /* best-effort */ }); }, START_DELAY_MS); };
        var idle = /** @type {any} */ (window).requestIdleCallback;
        if (typeof idle === 'function') idle(start, { timeout: 10000 });
        else setTimeout(start, 1000);
    }

    try {
        if (performance.setResourceTimingBufferSize) performance.setResourceTimingBufferSize(1000);
    } catch (_) { /* default buffer */ }

    if (document.readyState === 'complete') scheduleAfterIdle();
    else window.addEventListener('load', scheduleAfterIdle, { once: true });
}());
