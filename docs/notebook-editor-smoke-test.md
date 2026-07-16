# Pre-merge browser smoke test for the notebook editor

Status: **implemented (Phase 1), advisory.** The harness lives in
`Tools/editor-smoke-test/` and runs in CI via the `Editor smoke test` workflow
(nightly + path-filtered per-PR). Companion to the editor telemetry
(`editor_ready` / `sw_state` / `byBrowser`).

## Status update — what shipped

Phase 1 + assertion (5) are in: headless Chromium, full-app harness, assertions
(1)–(5) below, advisory. It is **verified to catch the regressions it exists
for** — run `Tools/editor-smoke-test/selftest.sh`, which boots the same server
build three ways. The editor is now cross-origin isolated **unconditionally**
(SharedArrayBuffer path), so the configs are:

```
default boot:                          crossOriginIsolated=true   SMOKE PASS  (kernel ran 7*191=1337, input() round-tripped over SAB)
SMOKE_SIMULATE_FROZEN=1 (no SW):       crossOriginIsolated=true   SMOKE PASS  (SAB carries stdin — kernel independent of the SW)
SMOKE_SIMULATE_NO_SYNC=1 (no SW/SAB):  crossOriginIsolated=false  SMOKE FAIL  (input() hung — "Page Unresponsive")
```

- **COEP worker-block** (#960/#961): the cross-origin-isolated editor page used
  to refuse its own fast-path-served Pyodide kernel worker (the worker script
  lacked COEP). Fixed by stamping COEP on the fast-path assets; the default
  config now *passes* isolated and is the live guard for that regression.
- **SW independence**: `SMOKE_SIMULATE_FROZEN=1` disables the service-worker
  manager; under isolation SAB still carries synchronous stdin, so the editor
  stays healthy — proving the kernel no longer depends on the SW (the fix for
  the "Kernel Unknown" SW-control race).
- **Freeze** (#959): `SMOKE_SIMULATE_NO_SYNC=1` disables the SW *and* strips the
  isolation headers off the document, so there is neither SW nor SAB and
  `input()` hangs. The trivial `7*191` cell still runs in this config — which is
  exactly why a liveness-only check missed the freeze and the `input()` probe was
  needed.

The decisions below were resolved as: **Chromium + WebKit** (CI runs the selftest
under both engines via a matrix — `SMOKE_BROWSER`; WebKit is the Safari engine and
is what catches the Safari-class regressions a Chromium-only check shipped blind);
**requireable** (the always-runs gate is now in place — see below); **full app**
harness (it drives the real `/jupyterlite/repl` through the real middleware chain,
no course seeding). The original proposal follows for context.

## Make it a required gate — IMPLEMENTED (one setting left)

The always-runs gate is now built into `editor-smoke.yml`. The workflow no longer
path-filters at the trigger; instead:

1. a **`changes`** job decides whether the PR touched the editor/grading/isolation
   surface (git-diff against the base; fail-safe — any uncertainty runs the smoke);
2. the expensive **`smoke`** matrix (Chromium + WebKit) runs only when it did;
3. an always-running **`editor-smoke-gate`** job reports the single status: green
   when the smoke passed **or was skipped** (no editor changes), red only when the
   smoke actually failed — and red if change-detection itself failed (fail closed).

So every PR reports `editor-smoke-gate`, and it never spuriously blocks an unrelated
PR. The **one remaining step is a repo setting** (not in this file): in branch
protection for `main`, add **`editor-smoke-gate`** to the required status checks.
Do NOT require the matrix legs (`smoke (chromium)` / `smoke (webkit)`) directly —
they are skipped on non-editor PRs and would block those merges; require only the
gate.

## Why

Every notebook-editor breakage in the last few weeks shipped **blind** — there
was no browser in the loop until students hit it in production:

- the COEP cross-origin-isolation attempt **blocked the Pyodide kernel worker**
  (it loaded a kernel only to refuse the worker script);
- disabling the service worker introduced the **"Page Unresponsive" freeze**;
- re-enabling it risks reviving **"Kernel Unknown"**.

None of these are catchable by our current CI. `swift test`, the render tests,
and the `BrowserRunnerJSTests` (node `vm`) all prove code/templates *resolve* —
none of them actually **boot the JupyterLite editor in a browser** and check the
kernel comes up. The runtime telemetry we just added tells us *after the fact*;
this smoke test is the *before-merge* gate.

## What it asserts

Load the real editor in a headless browser against a running server and assert:

1. The notebook page renders and the **JupyterLite iframe loads** (not a blank
   `ERR_BLOCKED_BY_RESPONSE`).
2. The kernel reaches **Idle** within a timeout (i.e. `editor_ready` fires, and
   no `watchdog_timeout` / `kernel-unhealthy` / "Kernel Unknown").
3. The browser console shows **no blocked-resource errors** (`ERR_BLOCKED_BY_RESPONSE`,
   COEP/CORP refusals) — this is exactly what last night's COEP attempt tripped.
4. A trivial cell **executes** (e.g. `1+1` → `2`), proving the kernel actually runs.
5. (Stretch) a cell calling `input()` does not hang — the freeze regression.

Each of those maps directly to a breakage we shipped. (1)+(3) catch the COEP
worker-block; (2) catches Kernel Unknown; (5) catches the freeze.

## Approach

- **Tool:** Playwright (headless Chromium first; Firefox + WebKit/Safari are a
  cheap add and WebKit is where Kernel Unknown / cross-process iframe quirks
  live).
- **Harness:** boot `chickadee-server` with a seeded course + a browser-graded
  notebook assignment + a logged-in student session (reuse the test fixtures /
  `makeTestApp` seeding patterns), then drive the editor URL.
- **CI:** a new job in the existing workflow, gated per-PR like `build`. Budget
  ~1–3 min. The vendored Pyodide/JupyterLite are already in-repo, so no
  network fetch.

## Decisions needed (greenlight)

1. **Browsers:** Chromium only to start, or Chromium + WebKit from day one?
   (WebKit doubles the value for the Safari/managed-device blind spot but adds
   setup + runtime.)
2. **Blocking vs advisory:** required check (blocks merge) or advisory at first
   while we shake out flakiness? Recommend **advisory for ~1 week, then
   required** once it's proven stable.
3. **Server fixture:** spin up the full app, or a trimmed editor-only harness?
   The full app is more faithful (it exercises the real middleware chain —
   which is where COEP/headers actually bit us), so recommend full app.

## Phasing

1. **Phase 1 (small):** Chromium, full-app harness, assertions (1)–(4),
   advisory. This alone would have caught both COEP breakages.
2. **Phase 2:** add WebKit + assertion (5) (`input()` no-hang). Promote to a
   required check.
3. **Phase 3:** matrix the COEP/SW configurations so we can *prove* a given
   editor config boots before enabling it — turning "browser-test on staging"
   into an automated gate.

## Relationship to the runtime telemetry

The telemetry (`editor_ready` rate, `sw_state`, `byBrowser`) tells us how the
editor behaves **in the field, across real devices** — including the managed
devices CI can't easily emulate. The smoke test tells us a change is safe
**before it ships**. We want both: the smoke test stops the obvious breakages at
the gate; the telemetry catches the device-specific long tail.
