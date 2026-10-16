# JupyterLite — Area Rules

Claude Code loads this file when it works under `Tools/jupyterlite/`. The rules
for the whole repository are in the root `CLAUDE.md`.

---

Chickadee embeds JupyterLite at `Public/jupyterlite/` for in-browser notebook
editing. The config is in `Tools/jupyterlite/`. `Public/jupyterlite` is generated
output and is checked in. The measurements and the history behind each rule
below are in [docs/jupyterlite.md](../../docs/jupyterlite.md).

- **Every vendored kernel is a xeus kernel, one environment each**
  (`Tools/jupyterlite/environment-<language>.yml`). The environments are
  separate on purpose, because a kernel fetches its whole environment at boot.
  `check-xeus-vendored.sh` asserts that they stay distinct. A vendored kernel
  appears in the editor's picker, so a language that can be authored must be
  one that can be graded.
- **The channel is `emscripten-forge-4x`.** The `emscripten-forge-dev` alias
  serves the frozen 3x channel. Do not point an environment file at it.
- **A student can import only what the environment contains.** The CSP is
  `connect-src 'self'`, so there is no runtime install.
- **Import checks read the vendored bytes, never the environment YAML.**
  `KernelImportGuard` refuses a browser-graded script whose imports the kernel
  cannot satisfy, from `importable-modules.json`.
- **A name in an environment file changes nothing until the kernel is rebuilt.**
  Re-vendor with `.github/workflows/revendor-kernels.yml`.
  `check-env-vendored-sync.sh` compares the declared packages with the shipped
  bytes.
- **A package has two costs: boot, paid by everyone, and attach, charged to the
  10-second test limit. Be sparing.** Measure with `Tools/browser-grading-smoke`.
- **A guard derivation must assert its own completeness, and a guard whose
  answer depends on the CI event it runs under is not a guard.** The
  `chickadee-*` glob in `build-jupyterlite.sh` still fails open for a kernel it
  does not know.
- **The vendored `pyodide-http` and the waitAsync polyfill worker are patched,
  and must stay patched** (`scripts/patch-*.py`, asserted by
  `check-xeus-vendored.sh` and `verify-jupyterlite.sh`).
- **Synchronous stdin uses a different transport per engine.** Read the
  middleware, not `jupyter-lite.json`: Chromium and Firefox are isolated and use
  `SharedArrayBuffer`; WebKit is not isolated and uses the service worker.
- **Chickadee's own extension is `chickadee-extension/`** (NB2). Its
  labextension is built with `jlpm build` and committed;
  `scripts/vendor-chickadee-extension.sh` puts it and `overrides.json` into the
  bundle, and `--check` fails CI when they drift. The overrides must keep the
  notebook toolbar's `executionProgress` item, because the boot diagnostics
  read the kernel state from it. See `docs/notebook-editor-extension.md`.
- **jszip, CodeMirror and the xeus bootstrap are vendored under `Public/vendor/`**,
  so no page load reaches a third-party CDN. Pyodide is gone (v0.5.19).
  `'unsafe-eval'` cannot be narrowed to `'wasm-unsafe-eval'`, because JupyterLab
  compiles JSON-schema validators at run time.

---

## Kernels

- **Mask the exit call.** The kernels mask R `quit()`, Lua `os.exit`, and
  Octave `exit` and `quit`. The Java wrapper requires a sentinel line, because
  `System.exit(0)` cannot be masked. If a mask regresses, every test reads as a
  pass.
- **Budget one quirk per kernel, not the same one.** R's per-expression wait and
  its stderr trap did not occur on Lua or Octave.
- The runbook for a new kernel is `docs/adding-a-xeus-kernel.md`. Its
  §"Traps" lists the per-language literal traps.
