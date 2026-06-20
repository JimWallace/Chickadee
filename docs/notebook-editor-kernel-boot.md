# Notebook editor kernel boot — "Kernel Unknown" and the path to a deterministic fix

This note captures the in-browser editor's kernel-boot failure mode
("Kernel Unknown"), the mitigation shipped now, and the plan for the
durable root-cause fix (cross-origin isolation / `SharedArrayBuffer`).

It is the companion to [`docs/notebook-editor-smoke-test.md`](notebook-editor-smoke-test.md)
(the Playwright harness that gates this code) and the inline rationale in
`Sources/APIServer/Middleware/COEPMiddleware.swift` +
`NotebookAssetIsolationMiddleware.swift`.

## Symptom

A small, steady fraction of in-browser editor loads land on JupyterLite's
**"Kernel Unknown"** badge — the Pyodide kernel session never registers, so
the student can't run or (for browser-graded assignments) submit from the
editor. It surfaces in the admin diagnostics as
`watchdog_timeout` / `failedChecks: ["kernel-unhealthy"]`
(`get_browser_diagnostics`), and historically clustered on specific
browser/OS classes rather than being uniform.

## Root cause: the service-worker control race

The editor's current architecture (after the v0.4.465 → v0.4.467 sequence)
runs **without cross-origin isolation** (`NOTEBOOK_CROSS_ORIGIN_ISOLATION`
defaults off — `SecurityConfig.swift`), so there is **no `SharedArrayBuffer`**.
That leaves the **JupyterLite service worker** as the kernel's *only*
synchronous-execution path: it intercepts `/api/drive` and `/api/stdin/` and
broadcasts to the Pyodide kernel worker.

The kernel boots cleanly only if that service worker is **controlling the
page** when the kernel mounts its Drive. The vended SW does
`skipWaiting()` + `clients.claim()`, but on some devices/loads the SW is
**registered but not yet controlling** at kernel-mount time → the kernel
can't establish its sync path → it registers `dead`/`unknown` → "Kernel
Unknown".

Telemetry corroborates this exactly: the `sw_state` beacon reports
`registrations=1` (the SW *registered*) on loads that still hit
`kernel-unhealthy` — registration is not the same as control.

This is a **known, predicted recurrence**, not a new bug. The v0.4.467
changelog entry (which re-enabled the SW to kill the "Page Unresponsive"
freeze) names the follow-up verbatim: *"If it recurs, the follow-up is a
kernel-wheel patch gating `mountDrive` on the SW actually controlling the
page."*

## What shipped now (mitigation A): a real recovery ladder

The parent-side watchdog in `Public/notebook.js` (`armEditorWatchdog` /
`planKernelFailureResponse`) previously did **one** in-place iframe `src`
reset and then gave up — which is why failures showed up annotated
"persisted after auto-reload": the reset re-raced the same SW startup it was
trying to dodge.

The recovery is now a three-rung ladder, and every reload first waits for the
SW to settle:

1. **First failure → reload the iframe** (cheapest; clears most cold-boot
   races). But first `await whenServiceWorkerActive(5000)` so the fresh boot
   doesn't re-race SW activation.
2. **Second failure → reload the whole tab** (`window.location.reload()`).
   Only a full document load re-bootstraps the SW → client *control*
   relationship from scratch; an in-place iframe reset cannot. Guarded by a
   per-(tab, setup) `sessionStorage` flag (`chickadee:kernel-page-reload:<id>`)
   so it happens **at most once** and can never loop into a reload storm.
3. **Third failure → fail**: surface the upload fallback + the same
   `watchdog_timeout` / `kernel-unhealthy` diagnostic as before (classification
   unchanged, so the admin breakdown keeps bucketing it).

Pinned by `Tests/BrowserRunnerJSTests/watchdog-probe.test.mjs`.

This is a **mitigation, not a cure**: it still depends on the SW eventually
controlling the page. It should cut the persisted-failure rate materially
(most of these clear on a clean reload once the SW has settled), and it ships
behind no flag with instant rollback. Watch `get_browser_diagnostics`
(`watchdog_timeout` count and `byBrowser`) after deploy to confirm the rate
drops.

## The durable fix (plan C): cross-origin isolation + `SharedArrayBuffer`

The deterministic fix is to give the kernel a synchronous path that does **not
depend on SW control timing at all**: `SharedArrayBuffer`, which requires the
editor iframe to be **cross-origin isolated** (COOP `same-origin` + COEP
`require-corp`). With SAB available the kernel never needs the SW for sync, so
the race disappears. The plumbing already exists, gated off:

- `COEPMiddleware` stamps COOP/COEP on the `/testsetups/:id/notebook` page.
- `NotebookAssetIsolationMiddleware` stamps COOP/COEP + `Cross-Origin-Resource-Policy: same-origin`
  on `/jupyterlite/*` iframe assets.
- Both are driven by `NOTEBOOK_CROSS_ORIGIN_ISOLATION` (default off).

### Why it's still off — the blocker

This was tried unconditionally in v0.4.466 and reverted: under COEP
`require-corp`, **the Pyodide kernel worker fails to start**. The v0.4.469
editor-smoke *selftest* encodes this as a guarantee — it asserts the editor
**passes** on the default config and **fails** under
`NOTEBOOK_CROSS_ORIGIN_ISOLATION=true` ("the COEP worker-block"). So we cannot
just flip the flag; the worker-block must be fixed first.

### Leading hypothesis (to verify, not assume)

Under COEP `require-corp` on the iframe document, a dedicated Worker inherits
the policy and **every resource it pulls must be isolation-compatible**
(`Cross-Origin-Resource-Policy`, or CORS). The Pyodide kernel worker loads the
runtime + wheels from **`/pyodide/*`**, but only **`/jupyterlite/*`** is
stamped with CORP today (`NotebookAssetIsolationMiddleware` matches that prefix
only). `/pyodide/*` (and any other same-origin asset the isolated worker
fetches) is served by `FileMiddleware` with **no** CORP header. That mismatch
is the most likely cause of the worker-block.

### Proposed steps

1. **Reproduce locally** with the smoke selftest
   (`Tools/editor-smoke-test/selftest.sh`) and capture the *exact* console /
   network error from the COEP run — confirm whether it's a CORP rejection on
   `/pyodide/*`, the worker script itself, a `Blob:`/`importScripts` path, or
   a credentials issue. Do not proceed on the hypothesis alone.
2. **Stamp CORP on every same-origin asset the isolated worker loads** — at
   minimum extend `NotebookAssetIsolationMiddleware` (or add a sibling) to add
   `Cross-Origin-Resource-Policy: same-origin` to `/pyodide/*` and any other
   prefix the error implicates, *only when isolation is enabled* (keep the
   non-isolated path byte-identical).
3. **Re-run the selftest.** Success criterion: the COEP run **flips to PASS**.
   Update `selftest.sh` so the COEP config is now an *expected pass* (and keep a
   regression case for whatever the real failing config is, so the guard can't
   rot — e.g. isolation on but CORP deliberately withheld from `/pyodide/*`).
4. **Verify in real browsers** (Chrome + Safari + a managed device) via the
   smoke harness; this path is not fully CI-verifiable.
5. **Flip the default / make unconditional**, then **disable the JupyterLite
   service worker** again (it's only there for sync, which SAB now provides) —
   removing the freeze risk *and* the control race together. Reverse the
   `JupyterLiteConfigTests` SW guard accordingly.
6. **Promote the editor-smoke workflow from advisory to a required gate** once
   it reliably passes on the isolated config — that is what actually closes out
   "all editor-load issues fixed".

### Fallback if isolation can't be made to work

If the worker-block proves intractable, the v0.4.467-named alternative remains:
patch the pyodide-kernel so `mountDrive` waits on
`navigator.serviceWorker.controller` before using the SW sync path. This is
harder to do cleanly here than the nb_mypy wheel patch
(`scripts/patch-pyodide-kernel.py`), because the gating logic lives in
**content-hash-named webpack chunks** (`Public/jupyterlite/.../static/620.*.js`,
`644.*.js`) rather than a fixed-name Python member, so editing it is a
rebuild-the-bundle / upstream-patch effort and is not CI-verifiable.
Prefer plan C.

## Quick reference

| | Sync path | SW-control race? | Status |
|---|---|---|---|
| Today | JupyterLite service worker | **yes** (the bug) | shipped; mitigated by recovery ladder A |
| Plan C | `SharedArrayBuffer` (cross-origin isolation) | no | blocked on the COEP kernel-worker fix |
| Fallback | SW, gated on `serviceWorker.controller` | removed | last resort; webpack-chunk patch |
