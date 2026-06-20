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

## The durable fix (plan C): cross-origin isolation + `SharedArrayBuffer` — IMPLEMENTED

The deterministic fix is to give the kernel a synchronous path that does **not
depend on SW control timing at all**: `SharedArrayBuffer`, which requires the
editor iframe to be **cross-origin isolated** (COOP `same-origin` + COEP
`require-corp`). With SAB available the kernel never needs the SW for sync, so
the race disappears. Driven by `NOTEBOOK_CROSS_ORIGIN_ISOLATION` (still default
off — see rollout below):

- `COEPMiddleware` stamps COOP/COEP on the `/testsetups/:id/notebook` page.
- `NotebookAssetIsolationMiddleware` stamps COOP/COEP/CORP on the slow-path
  `/jupyterlite/*` editor HTML documents.
- **`EditorAssetFastPathMiddleware` stamps the same trio on the vendored asset
  trees it serves (`/jupyterlite/build`, `/jupyterlite/extensions`, `/pyodide`,
  `/vendor`)** — the fast-path-isolation fix (see below).

### Root cause of the historical worker-block (was: "why it's still off")

Cross-origin isolation was tried unconditionally in v0.4.466 and reverted
because **the Pyodide kernel worker failed to start** under COEP. The actual
mechanism, confirmed both statically and by reproducing it with the smoke
selftest:

`EditorAssetFastPathMiddleware` is registered **near the top** of the chain and
serves `/jupyterlite/build`, `/jupyterlite/extensions` (**including the Pyodide
kernel worker chunk** `…/pyodide-kernel-extension/static/620.*.js`), `/pyodide`
and `/vendor` by short-circuiting the responder chain — *before*
`NotebookAssetIsolationMiddleware` runs. So with isolation on, the editor HTML
became cross-origin isolated (`require-corp`) but the kernel **worker script was
served with no `Cross-Origin-Embedder-Policy` header**. Chrome requires a
dedicated worker spawned by a `require-corp` document to itself be served with
COEP `require-corp`, so it blocked the worker with `net::ERR_BLOCKED_BY_RESPONSE`
— the "fast-path-served kernel worker block".

(The earlier hypothesis was missing CORP on `/pyodide/*`. That was wrong:
`SecurityHeadersMiddleware` already sets COOP+CORP globally, and same-origin
subresources don't need CORP anyway. The single missing header was **COEP on
the worker chunk**, which only the bypassed isolation middleware would have
added.)

### The fix (fast-path isolation)

`EditorAssetFastPathMiddleware` is now isolation-aware: when
`NOTEBOOK_CROSS_ORIGIN_ISOLATION` is on it stamps COOP `same-origin` + COEP
`require-corp` + CORP `same-origin` on every asset it serves (shared with
`NotebookAssetIsolationMiddleware` via `Response.setCrossOriginIsolationHeaders()`
so the two can't drift). When the flag is off it's byte-identical to before.

**Proven via the headless-browser smoke harness** (`Tools/editor-smoke-test/`),
which boots a real server and drives the real JupyterLite kernel in Chromium.
`selftest.sh` now asserts three configs against one build:

1. default (service-worker path) → **PASS**, `crossOriginIsolated=false`;
2. `NOTEBOOK_CROSS_ORIGIN_ISOLATION=true` (SAB path) → **PASS**,
   `crossOriginIsolated=true`, and `input()` round-trips over `SharedArrayBuffer`
   with no service worker involved. This config is *also* the live worker-block
   guard — if the fast-path isolation regresses, the worker block returns and it
   flips to FAIL (and the new `SMOKE_EXPECT_ISOLATED=1` assertion catches a
   *silent* isolation regression that would otherwise pass via the SW fallback);
3. `SMOKE_SIMULATE_FROZEN=1` (no SW, no SAB) → **FAIL** (input freeze), proving
   the detector is still discriminating.

Swift unit coverage: `EditorAssetFastPathMiddlewareTests` now asserts the trio
is present with the flag on and absent with it off.

### Rollout (the remaining, deploy-time work)

The fix makes isolation *work*; turning it on in production is deliberately left
as an operator step so it can be staged with instant rollback (the flag needs no
redeploy):

1. **Enable on staging** (`NOTEBOOK_CROSS_ORIGIN_ISOLATION=true`) and verify the
   editor boots in each target browser — **Chrome and especially Safari** and a
   managed/locked-down device. Chromium is covered by the headless harness;
   Safari is not, and is the residual risk (see below).
2. **Enable in production.** Roll back instantly by clearing the flag if anything
   regresses.
3. **Then** consider disabling the JupyterLite service worker (it's only there
   for sync, which SAB now provides) to remove the freeze risk and the control
   race together, and reversing the `JupyterLiteConfigTests` SW guard. Keep the
   SW until isolation is default-on and verified everywhere — under isolation the
   kernel prefers SAB, so the SW just sits as a harmless fallback.
4. **Promote the editor-smoke workflow from advisory to a required gate** once it
   reliably passes on the isolated config.

### Residual risk: Safari + the `Atomics.waitAsync` `data:` worker

The pyodide-kernel polyfills `Atomics.waitAsync` (when the engine lacks it) with
a `new Worker("data:application/javascript,…")`. `data:` workers are blocked
under COEP `require-corp`. Chromium has native `Atomics.waitAsync`, so the
polyfill never runs there and the headless test passes; **Safari** is the one to
watch on staging — if it falls into the polyfill, the isolated kernel could
break. This is the main reason isolation stays opt-in until real-browser
verification.

### Fallback if isolation can't be made to work in some browser

The v0.4.467-named alternative remains: patch the pyodide-kernel so `mountDrive`
waits on `navigator.serviceWorker.controller` before using the SW sync path.
Harder to do cleanly here than the nb_mypy wheel patch
(`scripts/patch-pyodide-kernel.py`) because the gating logic lives in
content-hash-named webpack chunks rather than a fixed-name Python member.
Prefer plan C; this is a per-browser safety net only.

## Quick reference

| | Sync path | SW-control race? | Status |
|---|---|---|---|
| Default (flag off) | JupyterLite service worker | **yes** | shipped; mitigated by recovery ladder A |
| Flag on (plan C) | `SharedArrayBuffer` (cross-origin isolation) | **no** | implemented + headless-proven; opt-in pending real-browser rollout |
| Fallback | SW, gated on `serviceWorker.controller` | removed | per-browser safety net only |
