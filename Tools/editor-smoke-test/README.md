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
   fast-path-served kernel worker.

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

`run-smoke.sh` honours `CHICKADEE_SERVER_BIN`, `PORT`, and
`NOTEBOOK_CROSS_ORIGIN_ISOLATION`. To point the check at an already-running
server instead, call the check directly:

```bash
node editor-check.mjs http://127.0.0.1:8080
```

## Self-test (proving the guard discriminates)

`selftest.sh` runs the check twice against the same build and asserts it
**passes on the good config and fails on the COEP regression** — so the smoke
test can't silently rot into something that passes no matter what:

```bash
./selftest.sh
```

Demonstrated result (the production breakage, reproduced and caught):

```
=== selftest 1/2: default config — expect PASS ===
crossOriginIsolated = false
SMOKE PASS — kernel executed 7*191 = 1337 (isolated=false)

=== selftest 2/2: NOTEBOOK_CROSS_ORIGIN_ISOLATION=true — expect FAIL ===
crossOriginIsolated = true
SMOKE FAIL — blocked resource detected while waiting for the kernel (COEP worker-block)
  blocked resources:
    - requestfailed: .../jupyterlite/extensions/@jupyterlite/pyodide-kernel-extension/static/620.*.js — net::ERR_BLOCKED_BY_RESPONSE
```

## Notes

- `node_modules/` and the downloaded browser are **not** committed (see
  `.gitignore`); `package-lock.json` pins Playwright.
- The benign `@jupyterlab/codemirror-extension:commands … No provider for
  INotebookTracker` console error is the bare REPL (no notebook tracker) and is
  ignored — it is not a blocked-resource signal and does not fail the check.
