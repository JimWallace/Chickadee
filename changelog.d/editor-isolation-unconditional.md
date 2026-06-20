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
