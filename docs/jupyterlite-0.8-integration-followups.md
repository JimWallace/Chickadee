# JupyterLite 0.8 integration — robustness follow-ups (agent handoff)

**For:** an agent picking up the work of *fully* integrating JupyterLite 0.8 /
Pyodide 314 / Python 3.14 into Chickadee.

---

## ⚠️ START HERE — rebase on `main` first

This branch (`claude/magical-cori-lkj21x`, PR #1028) **predates the production
`exec_hang` fix.** That fix shipped on `main` as **v0.4.526** (#1029) — a
kernel-startup `os.chdir` wrapper (`scripts/patch-pyodide-kernel.py`) that
creates the notebook's Drive folder before chdir'ing into it. **Rebase this
branch on `main` to pick it up.** It's not 0.8-specific and applies unchanged on
0.8 (the root cause — a `FileNotFoundError` from chdir'ing into an unmounted
Drive folder — is identical across 0.7.6 and 0.8). Full record:
`docs/exec-hang-investigation.md`.

Two consequences:
- **0.8 does not need to fix the hang** — the chdir fix already does, on either
  version. 0.8's *only* remaining value is the newer runtime (Python 3.14).
- On 0.8, once the chdir fix creates the folder, JupyterLite populates it with
  the Drive's **support files** too (verified on main: a no-service-worker kernel
  reads a seeded support file). So the "support files visible to the kernel" item
  below is **resolved by the rebase**, not separate work.

## Status of 0.8 on this branch

**0.8 is NOT merged** — it's a deferred, documented reference (PR #1028, draft).
Production runs **0.7.6 + the chdir fix** (`main`). 0.8 was investigated, doesn't
fix the hang (the chdir fix does), **and regresses browser grading** (below), so
it was held. Two integration fixes are already in
(`Tools/jupyterlite/jupyter-lite.json` + the built bundle), required just to
reach a running kernel on 0.8:

1. **`contentsAllJsonFile: "all.json"`** — 0.8 gates server-side contents
   discovery on this PageConfig option; without it the editor can't find the
   per-student notebook ("Could not find content").
2. **`pyodideUrl: /pyodide/pyodide.mjs`** (ESM, not the UMD `pyodide.js`) — 0.8's
   kernel worker (`coincident`) loads Pyodide via ESM `import()`; the UMD build
   yields `loadPyodide: undefined`.

---

## 🔴 The blocker: browser grading regresses on Pyodide 314

This is the **main reason 0.8 isn't adopted** and the first thing to solve.

Browser grading (`grading-worker.js` / `browser-runner.js`, a **separate** Pyodide
from the editor kernel) is **intermittently broken on 0.8**: in repeated local
runs of the editor smoke (`notebook-page-check.mjs`) it passed ~5/6 and **hung
hard 1/6** (a true hang — passes complete in ~15 s, the failure never finished in
240 s). On 0.7.6 grading is reliable (the required `editor-smoke-gate` stays
green; production submit funnel is 100%). So **0.8 introduces a grading flake.**

What is NOT the cause (ruled out): the UMD-vs-ESM Pyodide load. Verified directly
that Pyodide 314 **loads and runs in a worker via the UMD `importScripts`
path, even with no `indexURL`** (the grader's exact call) — `6*7 == 42`. So
`grading-worker.js`'s loader is fine on 314; **the flake is in grading
*execution*** (two Pyodides under cross-origin isolation, or a 314/3.14 execution
race), not the loader. Reproduce with `notebook-page-check.mjs` (give it the full
240 s+ budget; a too-short outer timeout looks like a failure on a slow cold
grade). This must be reliable before 0.8 can pass `editor-smoke-gate` and merge.

## Validate the rest of the notebook lifecycle on 0.8

The harness only exercised *open → idle → execute* (+ the grading flake above).
Walk the rest on the 0.8 bundle and fix any 0.8 drift:

- **Save / autosave** of the working copy (`notebook.js` `contents.save` round-trip).
- **Reset notebook** (instructor + self; `WebRoutes+EditorReset`).
- **Validation run** (instructor "validate"), `assignment-validate.js`.
- **Instructor authoring** — solution edit, new-assignment draft, JupyterLite launch.
- **Personalization** browser paths that touch `/pyodide` (`pyodide-worker.js`,
  `assignment-validate.js`, `notebook.js`, `browser-runner.js`).
- (**Support files** — resolved by the chdir fix; see START HERE.)

## Vendored extras ABI on Python 3.14

`Tools/vendor/pyodide-extra-packages.json` + `scripts/add-pyodide-extras.py`
inject extra wheels; `check-pyodide-parity.sh` asserts they're present. After the
0.8 re-vendor the lock holds `comm`, `astor`, `mypy_extensions`, `nb_mypy` (all
`py3-none`, so 3.14-safe). Verify:

- Any **compiled** extra (e.g. a future `mypy`) is a **cp314 / 2026_0** wheel, not
  a stale cp313/2025_0 one (would silently fail to load on 3.14).
- `comm` actually loads on 314 (the kernel uses it for outputs).
- nb_mypy stays **disabled** until type-checking is reworked off the cell-execute
  path. (Note: on `main` the activation block now carries the chdir fix; after
  rebasing, keep nb_mypy disabled within it.)

## Cosmetic / housekeeping

- `appVersion` is `0.8.0-chickadee.1` in **both** the source and built
  `jupyter-lite.json` (`build-and-verify` enforces they match — keep in sync on
  any re-vendor).
- Re-vendoring order: `setup-jupyterlite.sh` → `build-jupyterlite.sh` →
  `setup-vendor.sh`. The Pyodide version is **derived from the kernel** (314.0.0);
  don't hardcode it.
- `Public/pyodide` is ~510 MB on 314 (down from ~1.4 GB on 0.28); checked in.

## Robustness upgrade — the iframe command bridge

0.8's ecosystem ships **`jupyter-iframe-commands`** — a supported replacement for
`notebook.js`'s fragile `frame.contentWindow.jupyterapp.commands.execute(…)`
poking (the `jupyterapp` global is reachable in Chromium but flaky/absent in
WebKit, which is why those sites are wrapped in defensive
`if (win && win.jupyterapp)` guards and try/catch). It does **not** fix the
grading work above; it's an independent durability win.

**Shipped (#1035 — the bridge) + (this PR — save migration):**

- `jupyter-iframe-commands==0.3.0` is in `Tools/jupyterlite/requirements.txt`,
  federated into the bundle (auto-discovered by `jupyter lite build`, in
  `Public/jupyterlite/jupyter-lite.json`'s `federated_extensions`; the
  labextension auto-starts inside the iframe and `expose`s the command registry
  over comlink/postMessage).
- `jupyter-iframe-commands-host` is vendored to
  `Public/vendor/iframe-commands-host.js` (ESM, comlink folded in; built by
  `scripts/setup-vendor.sh` from `Tools/vendor/iframe-commands-host-entry.js`).
  `createBridge({ iframeId })` → `.ready` / `.execute(cmd, args)` / `.listCommands()`.
- `notebook.js` has a `getCommandBridge()` (lazy, cached, readiness-bounded) +
  `executeEditorCommand(command, args)` helper: **bridge-first with a
  `jupyterapp` poke fallback**. The save flushes — `window.chickadeeSaveNotebook`
  (idle-logout) and the pre-read flush in `readNotebookFromJupyterFrame` — now
  route through it, so they're reliable under WebKit isolation.
- **CI probe:** `Tools/editor-smoke-test/notebook-bridge-check.mjs` +
  `.github/workflows/notebook-bridge-probe.yml` (chromium+webkit, non-required
  diagnostic) drives `docmanager:save` directly through the bridge AND via the
  migrated `window.chickadeeSaveNotebook()`, asserting both persist across reload.

**Still on the `jupyterapp` poke (NOT yet bridged) — needs a custom labextension:**

These live *inside* functions that already require direct `app` access, so the
bridge adds no value piecemeal — comlink can only ferry structured-cloneable
data, not live JupyterLab objects:

- **Notebook read-back** (`readNotebookFromJupyterFrame` → `app.shell`,
  `notebookWidgetFromShell`, `widget.context.model.toJSON()`,
  `app.serviceManager.contents.get`). Falls back to the server snapshot
  (`fetchNotebookSnapshot`) when the frame read fails, so it's already resilient.
- **Server-snapshot reseed** (`syncNotebookFromServerSnapshot` → `contents.save`,
  then `docmanager:open` returning a `widget` whose `context.revert()` is called).
  The widget can't cross the comlink boundary.
- **Readiness probes** (`probeIframeReadiness`, `waitForJupyterApp`) read
  `win.jupyterapp`; already hardened with DOM-presence fallbacks.

**To fully retire the `jupyterapp` poke:** add a thin Chickadee labextension that
registers serializable commands inside the iframe — e.g. `chickadee:read-notebook`
(returns the notebook JSON) and `chickadee:reseed` (does the `contents.save` +
open + `context.revert` atomically and returns a boolean). Then the read/reseed
paths can move to `bridge.execute(...)` too. Larger effort (new labextension +
build/federation wiring + tests); its own PR.
Docs: https://jupyterlite.readthedocs.io/en/latest/howto/configure/advanced/iframe.html

## Note on the iframe itself

0.8 does **not** add a non-iframe notebook embedding (the removed
`@jupyterlite/iframe-extension` is the `IPython.display.IFrame` output renderer,
unrelated to app embedding). The bare top-level notebook app was tested and
behaves identically — the iframe is not the issue; keep it.
