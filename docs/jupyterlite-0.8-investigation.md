# JupyterLite 0.8 investigation — does it fix the editor `exec_hang`?

**Date:** 2026-06-24 · **Verdict: NO.** JupyterLite 0.8 / Pyodide 314 /
Python 3.14 does **not** fix the in-browser editor cell-execute hang
(`exec_hang`). This branch carries the full 0.8 upgrade as a **documented,
non-merge reference** so the integration work isn't lost and the negative
result is reproducible.

> **Update (resolved):** the `exec_hang` was later root-caused and fixed on
> `main` — **v0.4.526 / #1029** — a kernel `os.chdir` wrapper that creates the
> notebook's Drive folder before chdir'ing into it. The fix is **not 0.8-related**
> (it applies on 0.7.6 and 0.8 alike), so this doc's verdict stands — *0.8 itself
> doesn't fix the hang* — but the hang is no longer open. The "Why the negative
> result is valuable" section below drew the **wrong** mechanism (it guessed a
> SAB/MessageChannel deadlock); see `docs/exec-hang-investigation.md` for the
> actual cause (a `FileNotFoundError` from an unmounted Drive folder).

## What was upgraded

- `Tools/jupyterlite/requirements.txt`: `jupyterlite`, `jupyterlite-core`,
  `jupyterlite-pyodide-kernel` → **0.8.0**.
- Rebuilt bundle (`Public/jupyterlite`) — all Chickadee build patches survived
  the major jump (data:→blob: worker rewrite, diagnostics injection, the
  wheel→all.json→pipliteUrls sha chain; `verify-jupyterlite.sh` passes).
- Re-vendored **Pyodide 314.0.0 / Python 3.14.0** (`Public/pyodide`, ABI
  `2026_0`). Note Pyodide's new Python-aligned versioning: `314.0.0` *is* the
  Pyodide version (0.28 → 314), not a typo.

## 0.8 is not a drop-in — two integration breaks (both fixed here)

0.8 changed our notebook-content + kernel-Pyodide wiring. Without these two
config changes the editor never reaches a running kernel, so the hang can't
even be evaluated. Both are in `Tools/jupyterlite/jupyter-lite.json` (source of
truth) and the built `Public/jupyterlite/jupyter-lite.json`:

1. **Content loading — `contentsAllJsonFile: "all.json"`.**
   0.8's contents drive gates server-side directory discovery on a new
   PageConfig option:
   ```js
   let s = PageConfig.getOption("contentsAllJsonFile");
   if (!s) return /* empty dir, NO fetch */;
   fetch(URLExt.join(getBaseUrl(), "api/contents", dir, s)); // → api/contents/<dir>/all.json
   ```
   Unset → the drive never queries our `JupyterLiteContentsRoutes`
   (`/jupyterlite/api/contents/.../all.json`), so the per-student working copy
   the server writes to `Public/jupyterlite/files/users/<uid>/<setup>/assignment.ipynb`
   is invisible → *"Could not find content with path …"*. 0.7.x fetched it
   unconditionally; 0.8 made it opt-in. Setting it to `all.json` restores the
   exact request shape our routes already serve (verified: all manifests + the
   `files/` notebook fetch return 200).

2. **Kernel Pyodide load — `pyodideUrl: /pyodide/pyodide.mjs` (ESM, not UMD).**
   0.8's kernel worker (`coincident`) loads Pyodide via a dynamic **ESM
   `import()`** and destructures the namespace:
   ```js
   He(url){ return Function("u","return import(u)")(url) }
   async initRuntime(e){ let {loadPyodide:r} = await He(e.pyodideUrl); this._pyodide = await r({...}); }
   ```
   Our `pyodideUrl` pointed at the **UMD/IIFE** `pyodide.js` (`var
   loadPyodide=(()=>…)()`, no `export`), so the ESM import yields
   `loadPyodide === undefined` → `TypeError: r is not a function` in
   `Re.initRuntime`. The ESM build we already vend is `pyodide.mjs`
   (`export { … as loadPyodide, … as version }`). 0.7.x loaded Pyodide via
   classic `importScripts` (UMD); 0.8 switched to ESM.

## The result (both fixes applied): hang persists, identically

Editor loads → kernel boots → Pyodide 314 initializes → **first cell execute
wedges**. Bare `PythonError` (no message) in:

```
callPyObjectKwargs → callPyObjectMaybePromising → wrapper
  → MessageChannel.port1.onmessage           (pyodide.asm.mjs)
```

This is the **same signature** as the 0.7.6 production hang
(`callPyObjectMaybePromising → wrapper`); the `MessageChannel.onmessage` frame
is just Pyodide 314's async dispatch. `exec_hang busy_ms ≈ 46000` is the
watchdog threshold (a "hung past 46 s" marker), **not** a fingerprint.

## Why the negative result is valuable

The hang **survives** a full rewrite of everything above it: JupyterLite
0.7→0.8, the kernel worker switching to `coincident`, Pyodide **0.28→314**, and
Python **3.13→3.14**. That eliminated the entire JupyterLite / kernel /
Python-version surface and correctly pointed root-cause work at the **kernel
worker itself** rather than any version. (The original guess here — "a deadlock
in the SAB / MessageChannel round-trip" — was **wrong**; that frame is just the
WebLoop pumping.) Instrumenting the worker with an asyncio loop exception handler
then revealed the real failure: the kernel `os.chdir`'d into the notebook's Drive
folder, which our SW-disabled SAB-only config leaves **unmounted**, so a
`FileNotFoundError` died unhandled in the WebLoop and wedged the cell. Fixed on
`main` by creating the folder first (v0.4.526). Full record:
`docs/exec-hang-investigation.md`.

## Reproduce

With the 0.8 bundle on this branch and a local debug server
(`.build/debug/chickadee-server`):

```sh
SMOKE_BROWSER=chromium SMOKE_CHECK=editor-exec-check.mjs \
  bash Tools/editor-smoke-test/run-smoke.sh
```

Headless Chromium hangs 100% on both 0.7.6 and 0.8 (worst case; prod 0.7.6 is
~25%). The comparison is apples-to-apples — same env, same signature — so
"0.8 is no better" is solid.

## Status

The `exec_hang` is **fixed** on `main` (v0.4.526 — the kernel `os.chdir`
wrapper); the self-heal (v0.4.523, ~63 % recovery) is now a backstop, not the
primary fix. This branch is still **not for merge**: 0.8 doesn't fix the hang
(the chdir fix does) **and** regresses browser grading (~1/6 intermittent hang —
see `docs/jupyterlite-0.8-integration-followups.md`). It preserves the two 0.8
integration fixes in case 0.8 is wanted later for the newer runtime; whoever
takes that up should **rebase on `main` first** to inherit the chdir fix.
