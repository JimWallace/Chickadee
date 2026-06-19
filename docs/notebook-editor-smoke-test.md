# Pre-merge browser smoke test for the notebook editor

Status: **implemented (Phase 1), advisory.** The harness lives in
`Tools/editor-smoke-test/` and runs in CI via the `Editor smoke test` workflow
(nightly + path-filtered per-PR). Companion to the editor telemetry
(`editor_ready` / `sw_state` / `byBrowser`).

## Status update — what shipped

Phase 1 is in: headless Chromium, full-app harness, assertions (1)–(4) below,
advisory. It is **verified to catch the regression it exists for** — run
`Tools/editor-smoke-test/selftest.sh`, which boots the same server build twice
and asserts the editor **passes on the default config and fails under**
`NOTEBOOK_CROSS_ORIGIN_ISOLATION=true` (the COEP attempt, which makes the
cross-origin-isolated editor page refuse its own fast-path-served Pyodide kernel
worker → `net::ERR_BLOCKED_BY_RESPONSE`). Demonstrated result:

```
default config:                       crossOriginIsolated=false  SMOKE PASS (kernel ran 7*191=1337)
NOTEBOOK_CROSS_ORIGIN_ISOLATION=true: crossOriginIsolated=true   SMOKE FAIL (kernel worker ERR_BLOCKED_BY_RESPONSE)
```

The decisions below were resolved as: **Chromium-only** to start (WebKit is
Phase 2); **advisory** (not a required check — it is path-filtered, so a
required check would block the merge of every PR that skips it; promote to
required after it proves stable); **full app** harness (it drives the real
`/jupyterlite/repl` through the real middleware chain, no course seeding). The
original proposal follows for context.

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
