# Editor `exec_hang` — root cause, fix, and retrospective

**Status: RESOLVED.** Root-caused, fixed, shipped in **v0.4.526** (#1029), and
verified in production. This is the durable record of the in-browser notebook
editor cell-execute hang.

---

## Symptom

The JupyterLite/Pyodide notebook editor (`/testsetups/:id/notebook`) booted
normally to `kernel_idle`, then **the first cell execute wedged** — the cell sat
`[*]`/`[ ]` forever (past the ~45 s watchdog), a kernel restart did **not** clear
it, and it happened **across browsers**. Roughly **~25 %** of production sessions
(HLTH 230 lab) hit it; the headless repro reproduced it **100 %**. In JS it
surfaced as a bare, message-less `PythonError` at
`callPyObjectMaybePromising → wrapper → MessageChannel.onmessage`.

## Root cause

The kernel runs `os.chdir("users/<uid>/<setup>/")` at startup to set its working
directory to the notebook's Drive folder (the pyodide-kernel init script, gated
on `mountDrive`). **That folder only exists in the kernel's Pyodide filesystem
when the DriveFS is mounted — and the DriveFS has only a
`ServiceWorkerContentsAPI`, i.e. it needs the service worker.** We disable that
service worker to run **SAB-only under cross-origin isolation** (#989/#1003;
`SecurityHeadersMiddleware` keeps COEP off because the SW synthesises responses
without CORP). With no service worker the folder is absent, so `chdir` raises
`FileNotFoundError: [Errno 44] … 'users/<uid>/setup_<id>'`; that error is
**unhandled inside Pyodide's WebLoop**, so the execute coroutine never completes
and the cell hangs.

This explains every symptom:
- **REPL works** (`/jupyterlite/repl`): no notebook → no `chdir`.
- **~25 % vs 100 % headless**: students carrying a **stale SW registration** (from
  before #989) still had a working DriveFS, so the folder existed and they never
  hit it. Fresh / cleared clients (and every headless run) had no SW.
- **A kernel restart doesn't help**: restarting doesn't register a SW.

The real exception was invisible because it's a fatal-class error with no
formatted traceback; it was captured by instrumenting the kernel worker with an
asyncio loop exception handler + `sys.excepthook` (the `run()` wrapper never
fired — the coroutine dies before its body runs). NB: the earlier hypothesis that
this was a "SAB / MessageChannel deadlock in Pyodide's promising-call path" was
wrong — the `MessageChannel.onmessage` frame is just the WebLoop pumping the
coroutine that raises; the failure is the `chdir`, not the transport.

## The fix (v0.4.526)

`scripts/patch-pyodide-kernel.py` injects a kernel-startup wrapper that makes
`os.chdir` **create the target directory first** (`os.makedirs(path,
exist_ok=True)` then `chdir`). Properties:

- **Safe + targeted.** When the DriveFS already provides the folder (the working
  majority) `makedirs` is a no-op and behaviour is unchanged; when it's missing
  the kernel runs in the folder instead of hanging.
- **Restores support files too — not a partial fix.** Once the folder exists,
  JupyterLite populates it with the Drive's support files. Verified end-to-end:
  a no-DriveFS kernel reads a seeded support file (`open("data.txt")`) reliably.
- **Only the kernel wheel + its sha chain change** (wheel → `all.json` digest →
  `pipliteUrls` sha); the rest of the bundle and Pyodide are untouched.
- **Verified**: 100 % headless hang → **0 %**; `exec-probe` green on Chromium
  **and** WebKit.

It is **not** version-specific — the same bug and fix apply on 0.7.6 and on the
0.8 branch (which predates the fix; rebase to pick it up).

## Retrospective — what introduced and spread it (both ~2026-06-22)

- **#989 "Disable the redundant JupyterLite service worker — SAB only" — lit the
  fuse.** The DriveFS that mounts the notebook folder is serviced by that SW;
  disabling it made the `chdir` target absent. The SW was *not* redundant — it
  was load-bearing for the DriveFS.
- **#999 "restore kernel-boot fallback…" — spread it.** It added code
  (`notebook.js`, `cleanupRedundantServiceWorker`) that **actively unregisters the
  SW on every notebook load**. Students still carrying a working SW had their
  DriveFS deleted out from under them, so the hang rate climbed into the lab. The
  cleanup believed stale SWs *caused* boot failures; for the DriveFS they were
  keeping the kernel alive.

The self-heal (#1025) and `exec_hang` telemetry (#1023) treated the symptom and
remain useful (the self-heal recovered ~67 % of hangs before this fix).

## Follow-ups (optional, not blocking)

- The proper long-term answer to the SW/DriveFS tension is making the kernel's
  DriveFS work under SAB-only isolation (a SAB ContentsAPI, or re-enabling the SW
  in a COI-compatible way). The chdir fix makes this non-urgent — support files
  already reach the kernel.
- 0.8 upgrade is deferred: it doesn't fix this hang and regresses browser grading
  (see `docs/jupyterlite-0.8-integration-followups.md`).

---

## One-line summary

The kernel `chdir`'d into the notebook's Drive folder, which our SW-disabled
SAB-only config left unmounted, so a `FileNotFoundError` died unhandled in the
WebLoop and wedged the cell. Creating the folder first fixes the hang and lets
JupyterLite deliver the support files. Shipped v0.4.526; #989 introduced it,
#999 spread it.

---

# SECOND, DISTINCT ISSUE (2026-07-02) — the "~17 s slow first execute" is a premature-idle boot race, NOT the chdir hang

**Status: ROOT-CAUSED, fix pending a product decision.** The chdir bug above
is fixed. This is a *separate* phenomenon surfaced by the instrumented
`editor-exec-check.mjs` probe (see `docs/ci-flakiness.md`): on WebKit, ~30 % of
fresh kernels take **~16–18 s** before the first cell execute completes (the
other ~70 % and all of Chromium: ~505 ms). Its tail past the 45 s telemetry
threshold is the likely source of production's residual ~4 % `exec_hang`.

## Root cause — "idle" is reported before the kernel can execute

The DOM execution indicator (which `jl-kernel-diagnostics.js` reads to emit the
`kernel_idle` breadcrumb, and which the probe waits on) flips to idle off the
**`kernel_info_request` reply** — and in the vended pyodide-kernel driver
(`Public/jupyterlite/extensions/@jupyterlite/pyodide-kernel-extension/static/362.*.js`)
`kernelInfoRequest()` returns a **static object that does NOT `await this.ready`**.
So `kernel_info` is answered (busy → idle) while `initialize()` is still running.

`executeRequest()`, by contrast, **does** `await this.ready`. `ready` resolves
only after `initialize()` finishes, and `initKernel` inside it runs, sequentially:

```js
for (e of ["ipykernel","comm","pyodide-kernel","jedi","ipython"])
    install.push(`await piplite.install('${e}', keep_going=True)`);
install.push("import pyodide_kernel");   // full IPython InteractiveShell init
await this._pyodide.runPythonAsync(install.join("\n"));
```

So a first execute dispatched **before** `ready` resolves blocks on it for the
remainder of boot — a near-fixed wall-clock offset after the premature idle.
This explains every observed fact:

- **Fixed endpoint ~17 s after idle:** `initialize()` starts at boot and takes a
  near-fixed time; the `kernel_info` idle fires at a near-fixed early point;
  `ready` therefore resolves a fixed offset later. The delay experiment
  confirmed it: press at idle+0 ms → wait ~17 s; idle+1500 ms → wait ~15.7 s
  (band shifts down by the delay); idle+25 000 ms → 0/28 slow (`ready` long
  since resolved).
- **WebKit-specific ~17 s:** the dominant cost inside `initialize()` — compiling
  `pyodide.asm.wasm` and unpacking + importing the large pure-Python trees of
  **jedi + parso + ipython** into the Emscripten FS — is much slower on WebKit's
  WASM/JIT, and under SAB-only isolation every mounted-Drive FS touch is an
  `Atomics.wait` main-thread round-trip WebKit handles far worse than Chromium.
- **~30 % intermittent:** it is a race between `initialize()` completing and the
  first execute dispatching, with WebKit's WASM compile-cache hit/miss across
  fresh contexts driving the split (Chromium's reliable WASM caching → always
  fast).

Ruled out (evidence in the 2026-07-02 code map): our kernel patch (injects only
the synchronous `os.chdir` wrapper, schedules nothing), nb_mypy (disabled),
matplotlib inline (env-var only, no import at boot), and any completer warmup
(no `complete_request` is ever sent — inline providers default to `{}`, no
continuous hinting, notebook.js sends no kernel messages). The heavy boot item
is **jedi**, installed at boot solely to back tab-completion.

## Fix options (the product decision)

1. **Drop / defer jedi from the boot path.** jedi+parso are the bulk of the
   gated tail and are needed only for tab-completion, not to *run* a cell.
   Removing them from the boot install (or deferring jedi's load to the first
   completion request) shrinks the tail dramatically and likely eliminates the
   ~17 s window. **Tradeoff:** weaker/again-lazy tab-completion in the editor.
   Requires patching the vended kernel-extension bundle (fragile, minified) and
   browser-runtime verification.
2. **Preload the boot packages via `loadPyodideOptions.packages`** so they load
   in parallel at `loadPyodide()` time instead of sequential `piplite.install`.
   **Risk:** a package named there that fails to load rejects the whole boot
   (this is exactly why nb_mypy was NOT put there) — must be rock-solid.
3. **Honest readiness signaling + kernel warm-up.** Keep the editor showing
   "kernel starting" until `this.ready` actually resolves (not the `kernel_info`
   idle), and/or fire a hidden warm-up `pass` execute at boot so the ~17 s is
   spent visibly-starting *before* the student's first real run. Doesn't speed
   boot but removes the "I pressed run and it hung" experience; also makes the
   boot-funnel telemetry honest (today `kernel_idle` counts kernels still
   booting).

All three need a focused browser-verify loop (the probe is the acceptance test —
delay=0 webkit slow-rate must drop toward zero); none should be shipped to the
vended kernel bundle unverified, since a bad edit bricks editor boot for every
student.

## One-line summary (second issue)

The execution indicator reports "idle" off the `kernel_info` reply, which isn't
gated on `this.ready`, while the kernel is still installing jedi/ipython/etc.;
a cell run in that window blocks on `await this.ready` for the ~17 s remainder
of boot (WebKit-slow, cache-intermittent). Fix = get the heavy boot work
(jedi) off the pre-execute critical path and/or stop presenting a
still-booting kernel as ready.
