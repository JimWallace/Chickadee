### Fixed

- **Cross-origin isolation now works for the notebook editor — the deterministic
  fix for "Kernel Unknown".** Turning on `NOTEBOOK_CROSS_ORIGIN_ISOLATION` gives
  the Pyodide kernel `SharedArrayBuffer` for synchronous stdin/Drive, removing
  its dependence on the JupyterLite service worker and eliminating the
  service-worker-control race that caused the "Kernel Unknown" boot failures
  (the root cause behind the recovery-ladder mitigation). The flag had been
  unusable because, under COEP `require-corp`, the editor's Pyodide **kernel
  worker** is served by `EditorAssetFastPathMiddleware`, which short-circuits the
  chain *before* the isolation middleware ran — so the worker script went out
  with no `Cross-Origin-Embedder-Policy` header and Chrome blocked it
  (`ERR_BLOCKED_BY_RESPONSE`). The fast path is now isolation-aware: when the
  flag is on it stamps COOP/COEP/CORP on the vendored editor asset trees it
  serves (`/jupyterlite/build`, `/jupyterlite/extensions`, `/pyodide`,
  `/vendor`), via a shared `Response.setCrossOriginIsolationHeaders()` so the
  isolation middlewares can't drift. Proven end-to-end in the headless-browser
  smoke harness (`Tools/editor-smoke-test/selftest.sh`): the isolated config now
  boots the kernel with `crossOriginIsolated=true` and round-trips `input()` over
  `SharedArrayBuffer` with no service worker, while the freeze detector stays
  discriminating. The flag remains **default off** pending real-browser (esp.
  Safari) rollout — see `docs/notebook-editor-kernel-boot.md`.
