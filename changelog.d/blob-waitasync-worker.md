### Fixed

- **In-browser editor: boot the Pyodide kernel on engines without native
  `Atomics.waitAsync` (older Safari / iPadOS), with cross-origin isolation
  intact.** The kernel polyfills `Atomics.waitAsync` with a `data:` worker, which
  our CSP (`worker-src 'self' blob:`) and COEP `require-corp` both block on the
  isolated editor — hanging the kernel ("Kernel Unknown"-class). The polyfill
  worker is now vended as a `blob:` URL
  (`scripts/patch-pyodide-waitasync-worker.py`, run from the JupyterLite build and
  asserted by `verify-jupyterlite.sh`), which both CSP and COEP allow, so those
  engines boot the kernel on `SharedArrayBuffer` with **no fallback needed**. A
  new `SMOKE_SIMULATE_NO_WAITASYNC` editor-smoke config (CI, Chromium + WebKit)
  deletes native `waitAsync` and asserts the editor still boots isolated, so it
  can't regress unseen. This supersedes — and removes — the short-lived
  `ck-editor-compat` cookie fallback that dropped cross-origin isolation to use
  the service-worker path (`EditorCompatMode`, the COEP/asset-isolation cookie
  bypasses, and the `notebook.js` compat switch); the stale-service-worker
  cleanup and the `sw_state` `coi`/`waitasync` telemetry remain.
