### Fixed

- **Hardened the in-browser editor's recovery from "Kernel Unknown" boots.**
  When the Pyodide kernel registers `dead`/`unknown` at startup — the
  service-worker control race (the SW the kernel needs for its sync path is
  *registered* but not yet *controlling the page* when the kernel mounts its
  Drive) — the watchdog previously did a single in-place iframe reload and
  then gave up, so failures showed up annotated "persisted after auto-reload":
  the reset just re-raced the same SW startup. Recovery is now a three-rung
  ladder, and each reload first waits (bounded) for the service worker to
  settle: reload the iframe → reload the whole tab (a full document load is the
  only thing that re-bootstraps the SW → client *control* relationship; guarded
  by a per-(tab, setup) `sessionStorage` flag so it happens at most once and
  can't loop) → only then surface the upload fallback and the unchanged
  `watchdog_timeout` / `kernel-unhealthy` diagnostic. Mitigation, not a cure
  (it still depends on the SW eventually controlling); the deterministic
  root-cause fix (cross-origin isolation + `SharedArrayBuffer`, and why it's
  still blocked) is written up in `docs/notebook-editor-kernel-boot.md`. Also
  corrects a stale `COEPMiddleware` comment that claimed the JupyterLite service
  worker was disabled — it was re-enabled in v0.4.467.
