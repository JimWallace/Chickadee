# JupyterLite 0.8 integration — robustness follow-ups (agent handoff)

**For:** an agent picking up the work of *fully* integrating JupyterLite 0.8 /
Pyodide 314 / Python 3.14 into Chickadee.

**Context:** the 0.8 upgrade is **merged** and is now the baseline. It was
adopted to move forward on the latest runtime — **it does not fix the editor
`exec_hang`** (that's a separate, pre-existing bug; see
`docs/exec-hang-investigation.md`). Two integration fixes were required and are
already in (`Tools/jupyterlite/jupyter-lite.json` + the built bundle):

1. **`contentsAllJsonFile: "all.json"`** — 0.8 gates server-side contents
   discovery on this PageConfig option; without it the editor can't find the
   per-student notebook ("Could not find content").
2. **`pyodideUrl: /pyodide/pyodide.mjs`** (ESM, not the UMD `pyodide.js`) — 0.8's
   kernel worker (`coincident`) loads Pyodide via ESM `import()`; the UMD build
   yields `loadPyodide: undefined` ("r is not a function").

What was **verified** on 0.8: the editor boots, loads the seeded notebook
(`/api/contents` + `/files` all 200), the kernel reaches idle, and the REPL
executes. What was **proven broken (pre-existing)**: the first notebook cell
execute still hangs (see the other doc). Everything below is **not yet
verified** on 0.8 and needs a pass before we fully trust it in production.

---

## Validate the full notebook lifecycle on 0.8

The repro harness only exercised *open → idle → execute*. Walk the rest of the
real flows on the 0.8 bundle and fix any 0.8 drift:

- **Save / autosave** of the working copy (does `notebook.js`'s
  `contents.save` + the server working-copy round-trip still work?).
- **Submit** (browser-graded) — see grading section below.
- **Reset notebook** (instructor + self; `WebRoutes+EditorReset`,
  `data-working-copy-mtime` reseed logic in `notebook.js`).
- **Support files** — the working copy dir symlinks support files
  (`createSupportFileSymlinks`); confirm they're visible to the kernel on 0.8
  and that the contents/all.json directory listing includes them.
- **Validation run** (instructor "validate"), `assignment-validate.js`.
- **Instructor authoring** — solution edit, new-assignment draft, the
  JupyterLite launch from those pages.
- **Personalization** browser paths if any touch `/pyodide`
  (`pyodide-worker.js`, `assignment-validate.js`, `notebook.js`,
  `browser-runner.js` all load the one vended Pyodide).

## Browser grading on Pyodide 314

`browser-runner.js` loads Pyodide via `loadScript('/pyodide/pyodide.js')` +
`window.loadPyodide()` — i.e. the **UMD** build (still vended, sets
`globalThis.loadPyodide`). The editor **kernel** now uses the **ESM**
`pyodide.mjs`. Confirm:

- Browser grading still initializes + runs on **Pyodide 314 / Python 3.14**
  (the `pyodide.asm.{mjs,wasm}` changed shape vs 0.28).
- The required **`editor-smoke-gate`** (`notebook-page-check.mjs`) is green on
  0.8 — it covers boot + browser grading and is the gate that must pass to merge.
- Consider unifying both consumers on the ESM `pyodide.mjs` so there's one load
  path, or document why two are kept.

## Vendored extras ABI on Python 3.14

`Tools/vendor/pyodide-extra-packages.json` + `scripts/add-pyodide-extras.py`
inject extra wheels into the Pyodide lock; `check-pyodide-parity.sh` asserts
they're present. After the 0.8 re-vendor the lock holds
`comm`, `astor`, `mypy_extensions`, `nb_mypy` (all `py3-none`, so 3.14-safe).
Verify:

- Any **compiled** extra (e.g. a future `mypy`) is a **cp314 / 2026_0** wheel,
  not a stale cp313/2025_0 one (would silently fail to load on 3.14).
- `comm` actually loads on 314 (the kernel uses it for outputs).
- nb_mypy stays **disabled** (`scripts/patch-pyodide-kernel.py` injects an empty
  activation block) until type-checking is reworked off the cell-execute path.

## Cosmetic / housekeeping

- `appVersion` is `0.8.0-chickadee.1` in **both** the source and built
  `jupyter-lite.json` (the `build-and-verify` reproducibility gate enforces
  they match — keep them in sync on any re-vendor).
- Re-vendoring order is unchanged: `setup-jupyterlite.sh` →
  `build-jupyterlite.sh` → `setup-vendor.sh`. The Pyodide version is **derived
  from the kernel** (314.0.0); don't hardcode it.
- `Public/pyodide` is ~510 MB on 314 (down from ~1.4 GB on 0.28); it's checked in.

## Optional robustness upgrade — the iframe **command bridge**

0.8's ecosystem ships **`jupyter-iframe-commands`**: a supported host-page↔iframe
command API (`createBridge`, `commandBridge.execute('docmanager:open', …)`,
`listCommands()`). It is **still an iframe** and does **not** fix `exec_hang`,
but it could replace `notebook.js`'s fragile `frame.contentWindow` poking +
ad-hoc `contents.save` / `docmanager:open` calls with a maintained API. Evaluate
adopting it for robustness, independently of the hang.
Docs: https://jupyterlite.readthedocs.io/en/latest/howto/configure/advanced/iframe.html

## Note on the iframe itself

0.8 does **not** add a non-iframe notebook embedding. The only iframe-related
0.8 changelog entry removes `@jupyterlite/iframe-extension` (the
`IPython.display.IFrame` **output renderer** — unrelated to app embedding).
Loading the notebook app top-level (no iframe) was tested and still hangs, so the
iframe is **not** the issue — keep it.
