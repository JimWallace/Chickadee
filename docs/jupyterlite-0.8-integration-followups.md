# JupyterLite 0.8 integration — robustness follow-ups

> **Status (2026-07): 0.8 is MERGED and in production.** The upgrade to
> JupyterLite 0.8.0 / Pyodide 314 / Python 3.14 shipped in **v0.4.530**
> (2026-06-25); the 0.8.1 / Pyodide 314.0.1 point release followed in July
> 2026. Much of this document was written as a pre-merge handoff (PR #1028)
> and is kept for the record; sections below are annotated where the work has
> since landed. What remains genuinely open:
>
> - **The custom Chickadee labextension** to fully retire the `jupyterapp`
>   cross-frame poke (see "To fully retire the `jupyterapp` poke" below).
> - **The ambient WebKit grading/exec hang** — contained, not eliminated: the
>   grading-hang probe tolerates ≤1/12 on WebKit PR runs, browser grading
>   fails over to server-side grading on a bricked runtime, and the
>   editor-smoke gate retries WebKit legs once (see `docs/ci-flakiness.md`).
>
> The two 0.8 integration requirements described below
> (`contentsAllJsonFile: "all.json"`, ESM `pyodideUrl`) are live in
> `Tools/jupyterlite/jupyter-lite.json`. The chdir `exec_hang` fix (v0.4.526)
> is carried in the patched kernel wheel on every rebuild
> (`scripts/patch-pyodide-kernel.py`).

---

## The 0.8.0-era blocker: browser grading regressed on Pyodide 314

*(Historical — resolved by containment, not root-cause: bounded/instrumented
grading-worker init (v0.4.527), server-side grading failover when the browser
runtime can't start, and probe-level tolerance for the ambient WebKit hang
class. The description below is the original pre-merge finding.)*

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

*(Historical — this walk happened post-merge: save "Directory does not exist"
fixed in v0.4.540, reset-notebook IndexedDB eviction in v0.4.534, save flushes
moved onto the command bridge in v0.4.533, plus the lifecycle/bridge/reset CI
probes.)*

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
  `setup-vendor.sh`. The Pyodide version is **derived from the kernel** (314.0.1
  as of the 0.8.1 bump); don't hardcode it.
- `Public/pyodide` is ~465 MB on 314 (down from ~1.4 GB on 0.28); checked in.
  Since the 314.0.1 bump the tree carries exactly what `pyodide-lock.json`
  references (plus the core runtime and the Chickadee extras): stale
  prior-version wheels from an earlier vendor pass and Pyodide's self-test
  fixtures (`test_*` wheels/zips — absent from the lock, never loadable) were
  dropped (~45 MB).

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

**⚠️ `window.jupyterapp` is ABSENT on the 0.8 Notebook build.** Verified
empirically (the shell renders ~46 `jp-` nodes but the global never appears) and
already noted in `jl-kernel-diagnostics.js`. Consequence: every `notebook.js`
path that reaches for `frame.contentWindow.jupyterapp` was *silently* taking its
fallback on 0.8 — `readNotebookFromJupyterFrame` always falls back to the server
snapshot (fine, kept current by #1036's reliable saves), but the **reseed that
makes "Reset notebook" visible was a no-op → reset was broken on 0.8**. Fixed:

- **Server-snapshot reseed** (`syncNotebookFromServerSnapshot`) now has a
  jupyterapp-independent fallback. When the server working copy is newer than
  the seen baseline (a reset), it evicts the stale entry from JupyterLite's
  IndexedDB contents Drive (`"JupyterLite Storage"` → `files`, format-robust
  suffix match) via `evictNotebookFromDrive` and reloads with `reset=1`, so the
  editor re-fetches the freshly-reset static working copy from the server. Safe:
  a key mismatch makes eviction a no-op. (The old `contents.save` +
  `docmanager:open`/`revert` app path is kept for builds that *do* expose the
  global.) **Needs dev validation** — can't be exercised in the local static
  harness (the notebooks interface won't boot without the server's seeded
  per-student working copy + contents routes).

**Still on the `jupyterapp` poke (low value to bridge) — would need a custom labextension:**

- **Notebook read-back** (`readNotebookFromJupyterFrame` → `app.shell`,
  `widget.context.model.toJSON()`, `app.serviceManager.contents.get`). Already
  falls back to the server snapshot, which #1036 keeps current — so bridging it
  is now low value.
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
