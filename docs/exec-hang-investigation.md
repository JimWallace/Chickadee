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
fired — the coroutine dies before its body runs).

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
  (An earlier note called support files "a separate follow-up" — that proved
  unnecessary.)
- **Only the kernel wheel + its sha chain change** (wheel → `all.json` digest →
  `pipliteUrls` sha); the rest of the bundle and Pyodide are untouched.
- **Verified**: 100 % headless hang → **0 %**; `exec-probe` green on Chromium
  **and** WebKit.

It is **not** version-specific — the same bug and fix apply on 0.7.6 and on the
0.8 branch.

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
  (see `docs/jupyterlite-0.8-integration-followups.md` on the 0.8 branch).

---

## One-line summary

The kernel `chdir`'d into the notebook's Drive folder, which our SW-disabled
SAB-only config left unmounted, so a `FileNotFoundError` died unhandled in the
WebLoop and wedged the cell. Creating the folder first fixes the hang and lets
JupyterLite deliver the support files. Shipped v0.4.526; #989 introduced it,
#999 spread it.
