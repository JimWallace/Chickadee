### Fixed

- **Browser grading + the freeze failover are no longer blocked under the
  notebook editor's cross-origin isolation.** Making the editor unconditionally
  isolated meant the `/testsetups/:id/notebook` page is served `COEP: require-corp`
  — and a `require-corp` page cannot spawn a dedicated `Worker` whose script
  lacks COEP (Chrome `ERR_BLOCKED_BY_RESPONSE`). The app's own worker scripts
  (`/grading-worker.js`, `/freeze-watchdog-worker.js`) are served from the Public
  root, not the fast path that stamps COEP, so the global headers gave them CORP
  but never COEP — which would have silently broken in-browser grading and the
  main-thread freeze failover on deploy. `NotebookAssetIsolationMiddleware` now
  stamps the isolation trio on those two worker scripts as well.
  (`/pyodide-worker.js` is intentionally excluded — it is spawned only by the
  non-isolated assignment-editor pages.) Guarded going forward by a new
  worker-spawn probe in the editor-smoke harness — it spawns these workers from
  the isolated page under **both Chromium and WebKit** and fails if either is
  blocked — plus `COEPMiddlewareTests` coverage of the worker-script headers.
