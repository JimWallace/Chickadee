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

> Historical: this describes the architecture that *caused* the bug (no
> cross-origin isolation). Cross-origin isolation is now unconditional — see
> "The durable fix" below — so this race no longer occurs. Kept for context.

The pre-fix architecture (after the v0.4.465 → v0.4.467 sequence) ran
**without cross-origin isolation**, so there was **no `SharedArrayBuffer`**.
That left the **JupyterLite service worker** as the kernel's *only*
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

## The durable fix (plan C): cross-origin isolation + `SharedArrayBuffer` — SHIPPED (unconditional)

The deterministic fix is to give the kernel a synchronous path that does **not
depend on SW control timing at all**: `SharedArrayBuffer`, which requires the
editor iframe to be **cross-origin isolated** (COOP `same-origin` + COEP
`require-corp`). With SAB available the kernel never needs the SW for sync, so
the race disappears. Cross-origin isolation is now **unconditional** — there is
no env-var flag; the editor is always served isolated:

- `COEPMiddleware` stamps COOP/COEP on the `/testsetups/:id/notebook` page.
- `NotebookAssetIsolationMiddleware` stamps COOP/COEP/CORP on the slow-path
  `/jupyterlite/*` editor HTML documents.
- **`EditorAssetFastPathMiddleware` stamps the same trio on the vendored asset
  trees it serves (`/jupyterlite/build`, `/jupyterlite/extensions`, `/pyodide`,
  `/vendor`)** — the fast-path-isolation fix (see below).

(The `NOTEBOOK_CROSS_ORIGIN_ISOLATION` env var was removed. The middlewares keep
an `enabled`/`isolateNotebook`/`crossOriginIsolation` parameter as a unit-test
seam, but the bootstrap call site always passes `true`.)

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

`EditorAssetFastPathMiddleware` is now isolation-aware: it stamps COOP
`same-origin` + COEP `require-corp` + CORP `same-origin` on every asset it serves
(shared with `NotebookAssetIsolationMiddleware` via
`Response.setCrossOriginIsolationHeaders()` so the two can't drift).

**Proven via the headless-browser smoke harness** (`Tools/editor-smoke-test/`),
which boots a real server and drives the real JupyterLite kernel in Chromium.
`selftest.sh` asserts three configs against one build:

1. default boot → **PASS**, `crossOriginIsolated=true`, `input()` round-trips
   over `SharedArrayBuffer`. This is the live worker-block guard — if the asset
   middlewares stop stamping COEP on the kernel worker chunk, Chrome blocks the
   worker and it flips to FAIL (`SMOKE_EXPECT_ISOLATED=1` also catches a *silent*
   isolation regression);
2. `SMOKE_SIMULATE_FROZEN=1` (service worker disabled) → **still PASS**,
   `crossOriginIsolated=true` — with SAB carrying stdin the kernel no longer needs
   the SW, so killing it doesn't break the editor. This is the direct proof that
   the SW-control race is gone;
3. `SMOKE_SIMULATE_NO_SYNC=1` (SW disabled *and* isolation headers stripped off
   the document — no SAB either) → **FAIL** (input freeze), proving the detector
   is still discriminating.

The CI `editor-smoke` workflow runs this selftest on every editor-touching PR.
Swift unit coverage: `EditorAssetFastPathMiddlewareTests` asserts the header trio
is present when isolating and absent when not.

### Resolved: Safari/iPadOS + the `Atomics.waitAsync` `data:` worker

The pyodide-kernel polyfills `Atomics.waitAsync` (when the engine lacks it
natively — older Safari / iPadOS) with `new Worker("data:application/javascript,…")`.
A `data:` worker is blocked by our CSP (`worker-src 'self' blob:`) **and** by COEP
`require-corp` on the isolated editor, so the kernel hung ("Kernel Unknown"-class)
— confirmed by reproducing it with `SMOKE_SIMULATE_NO_WAITASYNC` (deletes native
`waitAsync`): `Refused to create a worker from 'data:…' … worker-src 'self' blob:`.

Fixed by vending the polyfill worker as a `blob:` URL instead
(`scripts/patch-pyodide-waitasync-worker.py`, run from `build-jupyterlite.sh` and
asserted by `verify-jupyterlite.sh`): a `blob:` worker is same-origin, inherits
the page's COEP, and is already allowed by the CSP — so these engines boot the
kernel **with cross-origin isolation (SharedArrayBuffer) intact, no fallback
needed**. Guarded in CI by the `SMOKE_SIMULATE_NO_WAITASYNC` editor-smoke config
(Chromium + WebKit), which deletes native `waitAsync` and asserts the editor
still boots isolated — the regression guard CI previously couldn't provide
(modern Chromium/WebKit both ship native `waitAsync`, so they never hit the
polyfill). The earlier per-client `ck-editor-compat` cookie fallback (which
dropped isolation to use the service-worker path) is removed: this fix keeps
isolation for everyone.

### Fallback if isolation can't be made to work in some browser

The v0.4.467-named alternative remains: patch the pyodide-kernel so `mountDrive`
waits on `navigator.serviceWorker.controller` before using the SW sync path.
Harder to do cleanly here than the nb_mypy wheel patch
(`scripts/patch-pyodide-kernel.py`) because the gating logic lives in
content-hash-named webpack chunks rather than a fixed-name Python member.
Prefer plan C; this is a per-browser safety net only.

### Service worker disabled (no safety net)

Now that cross-origin isolation is unconditional and `SharedArrayBuffer` carries
the kernel's synchronous stdin/Drive, the JupyterLite **service worker is
redundant and has been disabled** (`@jupyterlite/application-extension:service-worker-manager`
in `disabledExtensions`, both `Tools/jupyterlite/jupyter-lite.json` and the served
`Public/jupyterlite/jupyter-lite.json`). This is the deterministic end state:
**one sync path (SAB), no fallback** — which also removes the SW-control race
entirely (no SW to race) and the redundant SW asset cache. Guarded by
`JupyterLiteConfigTests` (now asserts the SW manager *is* disabled) and proven by
the editor-smoke selftest (editor boots + `input()` over SAB with no SW) and the
authenticated notebook-page e2e (the real editor loads the notebook from the
Drive and grades a real submission with no SW) — both under Chromium *and*
WebKit. One observed trade-off: without the SW asset cache, the page's two
Pyodide loads (editor kernel + grader) are heavier, so grading-to-result is
somewhat slower (noticeably under WebKit); it still completes.

## Observability: the in-iframe kernel-boot collector

The mitigations above fix *known* failure modes. But the parent notebook page
has a structural blind spot: it **cannot read the Pyodide kernel's state across
the cross-process editor iframe**. The shell mounting fires a green
`editor_ready`; if the kernel then silently never starts (the spinning-forever
symptom), the parent has no signal — `kernelLivenessReady` returns false even
for *healthy* kernels in that case, which is exactly why a deadline-based
parent-side beacon false-positived and had to be removed (see the NOTE in
`notebook.js`). So a hung kernel was invisible to telemetry.

`Public/jl-kernel-diagnostics.js` closes that gap. It is a passive observer
injected into the editor documents (`notebooks/` + `repl/index.html`) so it runs
**inside** the iframe — the one context where the boot is actually visible. It
`postMessage`s two breadcrumb kinds to the parent, which forwards them through
the normal client-diagnostics pipeline (the parent holds the session + CSRF
token — the bridge is `handleKernelDiagMessage` in `notebook.js`, which accepts
only same-origin `ck:'kernel-diag'` messages of an allowed kind):

- **`kernel_phase`** — `boot_start → app_ready → kernel_starting → kernel_idle`.
  The boot funnel; the drop-off point shows *where* a boot stalls. `kernel_idle`
  is the positive "the kernel actually came up" signal the parent could never
  get. This JupyterLite build (Notebook 7) does not expose `window.jupyterapp`
  at all — which is *why* the parent-side watchdog could never read kernel state
  — so detection reads the shell DOM instead: the notebook execution indicator's
  `data-status` (`.jp-Notebook-ExecutionIndicator[data-status]`, idle/busy/…),
  with the "Kernel status: …" text as a fallback. Cheap (a couple of
  `querySelector`s) and verified against the real editor by the authenticated
  `notebook-page-check.mjs` smoke test, which asserts the funnel reaches
  `kernel_idle` — without that, a detection mismatch would silently stall the
  funnel at `boot_start` and leave the collector polling the full boot deadline.
- **`kernel_error`** — the *why*: a CSP worker block (the historical
  `data:`-worker case), a blocked/404 asset, a dead/unknown kernel, or a
  boot-stall watchdog.

Capture is scoped to the **boot window** (it stops once the kernel idles), so it
never records student-code execution — same PII contract as the rest of
client-diagnostics. The admin tool `get_browser_diagnostics` aggregates the
`kernel_phase` events into a **`kernelBootFunnel`**: a `kernel_idle` count far
below `boot_start` is the hung-kernel signature, and the `kernel_error` rows
(in `bySource` / `recentSamples`) say why.

Wiring: the `<script>` tag is injected at build time by
`scripts/patch-jupyterlite-diagnostics.py` (run from `build-jupyterlite.sh`,
since `jupyter lite build` regenerates the index.html files) and asserted present
by `verify-jupyterlite.sh`. The editor-smoke harness asserts the collector
actually *runs* in a real browser under the live CSP/COEP (it must emit
`kernel_phase=boot_start`), and the collector + bridge logic is unit-tested in
`Tests/BrowserRunnerJSTests/kernel-diagnostics.test.mjs`.

## The post-idle exec_hang (a second, distinct failure mode)

Everything above is about the kernel **boot**. There is a second hang that the
boot story does not cover: a kernel that **boots to idle cleanly, then wedges
BUSY forever on a later cell** — the `[*]`-forever deadlock students hit in the
lab. It is invisible to the boot funnel and the watchdog *by construction*: both
stop the instant the kernel reaches `kernel_idle` (a successful boot), so a
kernel that fails *after* that point reports only success.

**Telemetry (`exec_hang`, shipped 0.4.522).** The in-iframe collector keeps one
narrow, PII-safe watcher alive after idle: it reads only the busy/idle indicator
and emits a single `kernel_error/source=exec_hang` (`busy_ms=…`) when a cell sits
busy past 45s. Production `get_browser_diagnostics` shows these on fully-capable
modern Chrome/Edge with `coi=true; sab=true; waitasync=true; registrations=0` —
i.e. **not** the no-SAB / no-waitAsync cohort the boot fixes targeted. The
signature is consistent with **background-tab throttling of the SAB/Atomics
handshake** (the main thread's `Atomics.notify` is deferred while the worker
blocks in `Atomics.wait`), which is why it is post-*idle* and why a headless CI
run cannot reproduce it (a Playwright tab is never backgrounded).

**Recovery (this change).** `exec_hang` was telemetry-only; the student hung
forever. The parent bridge (`notebook.js`) now drives a guarded recovery ladder
off that beacon — iframe-reload → page-reload → upload-fallback
(`planExecHangResponse`), reusing the boot ladder's reload primitives. A wedged
kernel holds no useful state after 45s busy, and JupyterLite restores the saved
notebook from IndexedDB on reboot, so the reload is a real recovery, not a loss.

**Observability (this change).** The `editorKernelHang` health-alert rule fires
when ≥`ALERT_EDITOR_HANG_THRESHOLD` exec_hangs land within
`ALERT_EDITOR_HANG_WINDOW_MINUTES`, so a recurrence pages instead of waiting for
a lab report.

**Root cause is still open.** The recovery + alert are a mitigation. The
underlying SAB/Atomics execution deadlock is not yet reproduced or fixed; a
falling `exec_hang` / `editorKernelHang` count is the success signal for that
follow-up.

### Lessons (so the 4-week arc doesn't repeat)

1. **A security-header change is an editor-runtime change.** Cross-origin
   isolation (COOP/CORP, #568) silently moved the kernel from the
   service-worker sync path onto SharedArrayBuffer+Atomics. Treat any change
   that flips `crossOriginIsolated` as a kernel change and gate it on the
   editor-smoke suite, not just the security review.
2. **Don't remove a fallback to "simplify" until the remaining path is proven
   across the full lifecycle.** "SAB only, no fallback" (#989) was verified at
   *boot*, on Chromium+WebKit, at t≈0 — not at steady-state or post-idle. The
   exec_hang appeared in exactly the lifecycle phase CI never exercised.
3. **Lead with telemetry, don't trail it.** Each round of this arc added
   observability *after* the incident. The post-idle watcher and the
   `editorKernelHang` alert now make this class of regression visible up front.

## Quick reference

| | Sync path | SW-control race? | Status |
|---|---|---|---|
| Before | JupyterLite service worker | **yes** | the bug; recovery ladder A mitigates it |
| Now | `SharedArrayBuffer` (cross-origin isolation) | **no** | shipped + headless-proven (both engines); **SW disabled** — one sync path, no fallback |
| Removed | SW, gated on `serviceWorker.controller` | n/a | the never-built fallback; unnecessary once SAB is the sole path |

| Failure mode | Phase | Seen by | Recovery |
|---|---|---|---|
| Boot hang (Kernel Unknown / never idles) | boot | boot funnel + watchdog | reload-iframe → reload-page (ladder A) |
| `exec_hang` (booted, then wedges busy) | post-idle execute | in-iframe `exec_hang` watcher | reload-iframe → reload-page → upload (`planExecHangResponse`) |
