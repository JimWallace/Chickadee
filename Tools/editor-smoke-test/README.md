# Notebook editor smoke test

A headless-browser smoke test that boots the **real** JupyterLite notebook
editor against a running `chickadee-server` and asserts the Pyodide kernel
actually comes up and runs a cell.

This is the gate the recent editor breakages slipped through. `swift test`, the
render tests, and `BrowserRunnerJSTests` all prove code/templates *resolve* —
none of them put a browser in front of the editor, so a change that loads the
page but **blocks the kernel worker** (the COEP cross-origin-isolation attempt)
or leaves a **dead kernel** ("Kernel Unknown") passes CI and only fails in front
of a student. This test catches that class of regression before it ships.

See `docs/notebook-editor-smoke-test.md` for the rationale, phasing, and the
open greenlight decisions (browser matrix, blocking-vs-advisory, CI wiring).

## What it asserts

Loading `/jupyterlite/repl/index.html` (the same Pyodide kernel + vendored
assets the student editor embeds, served through the same middleware chain —
including the cross-origin-isolation headers):

1. the editor shell mounts and the kernel boots;
2. a trivial cell **executes** (`7*191` → `1337`) — real liveness, not an
   internal flag;
3. **no blocked-resource errors** (`ERR_BLOCKED_BY_RESPONSE`, COEP/CORP
   refusals) appear in the console or network — this is exactly what the COEP
   attempt tripped, when the cross-origin-isolated page refused its own
   fast-path-served kernel worker;
4. **`input()` round-trips without hanging** — a cell calls `input()` and the
   harness answers the stdin prompt; the echo must come back. This needs the
   service worker (or SAB) for synchronous stdin, so it catches the "Page
   Unresponsive" freeze (#959) the trivial cell sails right through.

It is deliberately **auth-free**: the REPL and the vendored Pyodide/JupyterLite
assets are public static content, so no course/student seeding is needed — yet a
header/middleware regression still surfaces because the assets flow through the
real chain.

## Running it

```bash
# one-time: install the browser
cd Tools/editor-smoke-test
npm ci
npx playwright install chromium

# build the server (once), then run against a single config
swift build                      # from the repo root
./run-smoke.sh                   # boots a server, runs the check, tears down
```

`run-smoke.sh` honours `CHICKADEE_SERVER_BIN` and `PORT`; the `SMOKE_*` knobs
(`SMOKE_SIMULATE_FROZEN`, `SMOKE_SIMULATE_NO_SYNC`, `SMOKE_EXPECT_ISOLATED`,
`SMOKE_BROWSER`) are read by `editor-check.mjs`. The editor is cross-origin
isolated unconditionally, so there is no server-side isolation flag.

`SMOKE_BROWSER` selects the engine: `chromium` (default), `webkit` (the Safari
engine — install with `npx playwright install webkit`), or `firefox`. CI runs the
selftest under **both Chromium and WebKit**; run WebKit locally before shipping
editor changes, since every Safari-class editor bug we have shipped was invisible
to a Chromium-only check:

```bash
SMOKE_BROWSER=webkit ./selftest.sh
```

To point the check at an already-running server instead, call the check directly:

```bash
node editor-check.mjs http://127.0.0.1:8080
```

## Self-test (proving the guard discriminates)

`selftest.sh` runs the check three ways against the same build: the editor must
**boot isolated, survive losing the service worker (SharedArrayBuffer), and the
freeze probe must still catch a no-sync editor** — so the smoke test can't
silently rot into something that passes no matter what:

```bash
./selftest.sh
```

Demonstrated result:

```
=== selftest 1/3: default boot — expect PASS (isolated, SharedArrayBuffer path) ===
crossOriginIsolated = true
SMOKE PASS — kernel ran 7*191=1337 and input() round-tripped (isolated=true)

=== selftest 2/3: service worker disabled — expect PASS (SAB independent of the SW) ===
crossOriginIsolated = true
SMOKE PASS — kernel ran 7*191=1337 and input() round-tripped (isolated=true)

=== selftest 3/3: no SW and no SAB — expect FAIL (input freeze) ===
crossOriginIsolated = false
SMOKE FAIL — input() did not return — editor froze on stdin (no service worker / SAB)
```

The freeze case (3) rewrites `jupyter-lite.json` in-flight (`SMOKE_SIMULATE_FROZEN=1`)
to disable the service-worker manager — the #959 config — so the `input()`
probe is *proven* to catch the freeze, not just asserted to.

## Notes

- `node_modules/` and the downloaded browser are **not** committed (see
  `.gitignore`); `package-lock.json` pins Playwright.
- The benign `@jupyterlab/codemirror-extension:commands … No provider for
  INotebookTracker` console error is the bare REPL (no notebook tracker) and is
  ignored — it is not a blocked-resource signal and does not fail the check.
