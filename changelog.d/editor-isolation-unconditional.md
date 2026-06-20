### Changed

- **The notebook editor is now cross-origin isolated unconditionally — the
  `NOTEBOOK_CROSS_ORIGIN_ISOLATION` env var is removed.** The cross-origin
  isolation fix (which gives the Pyodide kernel `SharedArrayBuffer` and so
  eliminates the service-worker-control "Kernel Unknown" race) shipped behind a
  flag; it is now always on, so there is nothing to configure. The
  `AppSecurityConfiguration.notebookCrossOriginIsolation` field and the env read
  are gone; the isolation middlewares keep their `enabled`/`isolateNotebook`/
  `crossOriginIsolation` parameter purely as a unit-test seam, set `true` at the
  bootstrap call site. The headless editor-smoke selftest now proves the editor
  boots isolated, **stays healthy with the service worker disabled** (SAB carries
  stdin — the direct proof the SW-control race is gone), and still detects a
  genuine no-sync freeze. **Verify the editor on Safari before promoting a build
  to production** — the kernel's `Atomics.waitAsync` `data:`-worker polyfill is
  blocked under COEP, and Chromium (covered by the harness) has the API natively
  while Safari may not. Rollback is reverting the change (no flag). See
  `docs/notebook-editor-kernel-boot.md`.
- **Editor telemetry now reports cross-origin-isolation state.** The notebook
  page's `sw_state` beacon includes `coi=<crossOriginIsolated>;sab=<SharedArrayBuffer present>`
  so the admin browser-diagnostics breakdown can confirm — per browser/device
  class — that the SharedArrayBuffer path is live after a deploy, and correlate
  any "Kernel Unknown" failure with it (e.g. a browser reporting `coi=false`, or
  `kernel-unhealthy` with `coi=true`, is the one to investigate).
