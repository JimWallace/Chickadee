### Changed

- **Disabled the now-redundant JupyterLite service worker — the editor runs on
  SharedArrayBuffer alone, no fallback.** With cross-origin isolation
  unconditional, the kernel syncs stdin/Drive over `SharedArrayBuffer`, so the
  service worker (`@jupyterlite/application-extension:service-worker-manager`) is
  no longer needed and is now in `disabledExtensions` (source + served config).
  This is the deterministic end state: one sync path, no fallback — which also
  removes the SW-control "Kernel Unknown" race entirely (no SW to race).
  `JupyterLiteConfigTests` now asserts the SW manager is disabled. Verified by
  the editor-smoke selftest (kernel + `input()` over SAB with no SW) and the
  authenticated notebook-page e2e (the real editor loads the notebook from the
  Drive and grades a real submission with no SW), both under **Chromium and
  WebKit**. Trade-off: without the SW asset cache the page's two Pyodide loads
  are heavier, so grading-to-result is somewhat slower (noticeably under WebKit)
  but still completes — the notebook-page e2e's submit budget was widened
  accordingly. Its redundant active worker-spawn probe (which started a second
  Pyodide and could perturb the real grading) was removed in favour of asserting
  no COEP-blocked resources plus a clean `1 / 1 passed`, making the e2e
  deterministic across engines.
