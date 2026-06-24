# Editor `exec_hang` — investigation log & current understanding

**Status:** root cause **localized, not yet named to the exact line.** This is
the master notes file for the in-browser notebook editor cell-execute hang.
Keep it current as the hunt continues.

Related: `docs/jupyterlite-0.8-investigation.md` (the 0.8 upgrade experiment),
`docs/jupyterlite-0.8-integration-followups.md` (remaining 0.8 robustness work),
`docs/notebook-editor-kernel-boot.md` (kernel-boot history).

---

## Symptom

The in-browser JupyterLite/Pyodide notebook editor (`/testsetups/:id/notebook`)
boots normally to `kernel_idle`, then **the first cell execute wedges**: the
cell sits `[*]`/`[ ]` forever (past the 45 s watchdog), a kernel restart does
**not** clear it, and it happens **across browsers**. In production (HLTH 230
lab) roughly **~25 % of sessions** hit it; in the headless CI/local repro it
reproduces **100 %**.

**Failure fingerprint (consistent across every version tested):**
- A bare, **message-less `PythonError`** at
  `callPyObjectKwargs → callPyObjectMaybePromising → wrapper`
  (+ `MessageChannel.port1.onmessage` on Pyodide 314). The empty message means
  the Python-side traceback could not be formatted — a fatal/abort-class error,
  not an ordinary exception.
- The `exec_hang` beacon reports `busy_ms ≈ 46000`, which is just the watchdog
  threshold ("hung past ~46 s"), **not** a fingerprint of the cause.
- Occasionally a fatal `JSON Parse error: Unterminated string` (a truncated
  SharedArrayBuffer message), seen in some sessions.

---

## What it is NOT — ruled out with evidence

Each of these was tested, not assumed:

| Hypothesis | How it was ruled out |
|---|---|
| **nb_mypy** (the in-editor type checker) | Stripped it from the kernel wheel; the controlled repro still hung **8/8**, identical. (#1028) |
| **JupyterLite / pyodide-kernel version** | Hang **survives 0.7.6 → 0.8** (a full rewrite of the kernel/worker layer, incl. the switch to `coincident`). |
| **Pyodide version** | Survives **0.28 → 314**. |
| **Python version** | Survives **3.13 → 3.14**. |
| **Our iframe / `notebook.js` wrapper / orchestration** | The **bare** notebook app loaded **top-level (no iframe, no wrapper, no browser-runner, no freeze-watchdog)** hangs **identically**. (`bare-notebook-check.mjs`) |
| **Kernel core / Pyodide execute mechanism in general** | The **REPL** (`/jupyterlite/repl`, `editor-check.mjs`) executes cells fine on the same kernel + Pyodide. |
| **IPython cold-init in general** | The REPL cold-inits the same IPython shell and works. |
| **SAB/Atomics stdin transport** | The REPL's `input()` round-trip (which rides exactly that path) works. |
| **An HTTP Drive/contents fetch stuck** | No `/api/drive`, `/api/contents`, or `/files` request is **pending** at hang time — the worker is blocked in-process, not on the network. |
| **Grading-Pyodide / freeze-watchdog contention** | The grading Pyodide loads **lazily** (only on submit; absent at first-execute). The freeze-watchdog is a passive heartbeat observer (no SAB/Atomics). The REPL test page spawns both and still executes. |

---

## What it IS — current localization

The hang is specific to the **notebook frontend's asynchronous cell-execute
path** — `run_cell_async` → Pyodide's WebLoop (`callPyObjectMaybePromising`,
driven by a `MessageChannel`) — which dies with the message-less fatal
`PythonError` and never resolves, so the frontend waits forever.

The **discriminator** between "notebook hangs" and "REPL works," on an identical
kernel, is the kernel's **runtime environment**: the notebook session opens a
file from a per-student **Drive subdirectory** (`users/<uid>/<setup>/…`) and the
kernel mounts/operates in that Drive context; the REPL has **no file and no
mounted Drive**. The deadlock is **in-worker** (SAB, no HTTP), so the leading
mechanism is the **emscripten DriveFS synchronous path** (or something the
notebook *session* sets up around it), not a network call.

This makes it **our integration/config**, not a JupyterLite bug:

- We **disable the service worker** (`disabledExtensions:
  ["@jupyterlite/application-extension:service-worker-manager"]`) to run
  **SAB-only** under cross-origin isolation (#989, #1003). The bundle still
  ships `service-worker.js`, but it is **never registered**.
- JupyterLite's DriveFS classically services **synchronous** FS operations
  through that **service worker** (it intercepts `/api/drive/…`, using a
  `BroadcastChannel` + `Atomics`). The kernel chunk references `ServiceWorker`,
  `DriveFS`, `mountDrive`, `BroadcastChannel`, and `/api/drive`. With no SW
  registered, a synchronous DriveFS op during execute has **no responder** and
  blocks on `Atomics.wait` forever.

**Caveat:** re-enabling the SW in a single-load headless test did **not** clear
the hang — but that test is inconclusive (the SW almost certainly wasn't
*active/controlling* before the kernel mounted the Drive; SW activation needs a
second load, which the production `notebook.js` handles via
`whenServiceWorkerActive` but the bare probe does not).

### Why ~25 % in prod but 100 % headless (hypothesis)

Timing- and state-dependent. One plausible contributor: students with a
**leftover service-worker registration** from a pre-#989 build still have a
working DriveFS transport (no hang), while fresh/cleared clients have none
(hang). That would also explain "a kernel restart doesn't help" (restarting
doesn't register a SW) and the cross-browser spread. Not yet confirmed.

---

## Evidence harness (reproduce it)

All under `Tools/editor-smoke-test/`, run via
`SMOKE_CHECK=<probe> bash Tools/editor-smoke-test/run-smoke.sh` (boots a local
`chickadee-server` on SQLite, seeds through the real HTTP API, drives headless
Chromium/WebKit):

- **`editor-check.mjs`** — the REPL. **Passes** (executes cells, `input()`
  round-trips). The "kernel core is fine" control.
- **`editor-exec-check.mjs`** — the full `/testsetups/:id/notebook` page. **Hangs**
  (the production path). Loops `EXEC_ITER` to measure rate; reports `exec_hang`.
- **`bare-notebook-check.mjs`** — the **bare** notebook app, top-level, no
  wrapper. **Hangs** identically. The experiment that excluded our wrapper and
  pinned it to the notebook frontend. Captures the pageerror message + any
  drive/contents/files request still pending at hang time.

The `.github/workflows/editor-exec-probe.yml` runs `editor-exec-check.mjs` on
chromium + webkit (non-required diagnostic).

---

## Live mitigations (already shipped)

- **Self-heal** (v0.4.523, #1025): on an `exec_hang` beacon the parent bridge
  **auto-reloads the kernel iframe once** (work-preserving). Production recovery
  ≈ **63 %** (`recover_attempt` − `recover_failed` in `get_browser_diagnostics`).
  Still the main thing keeping the lab usable.
- **`/reset-editor`** (#1005): `Clear-Site-Data` page for a wedged student.
- **Telemetry** (#1023): the `exec_hang` beacon itself (`busy_ms`), surfaced in
  `get_browser_diagnostics` `bySource`.

---

## Open questions / next steps

1. **Name the exact failing call.** The bare `PythonError` carries no Python
   traceback. **Instrument the kernel worker** (patch `pyodide_kernel`'s `run()`
   / the WebLoop to log the live exception + the FS/await op preceding it) so the
   real failure is visible instead of a fatal blank. ← *the immediate next step.*
2. **Confirm/refute the DriveFS-without-SW theory** decisively — e.g. re-enable
   the SW *with* a proper activation+reload (as production `notebook.js` does)
   and re-test; or mount the kernel with **no** Drive and see if the notebook
   executes.
3. **Candidate fixes to evaluate** once the call is named: re-enable the SW
   correctly for the DriveFS (preserving cross-origin isolation); or deliver
   support files to the kernel **without** mounting the server-backed Drive; or
   change the notebook session's working-directory/FS setup.
4. **Prod vs headless rate** — verify the leftover-SW-registration hypothesis
   against real `get_browser_diagnostics` data.

---

## One-line summary

Same kernel, two frontends: the **REPL executes, the notebook hangs** — a
message-less fatal `PythonError` in the notebook's async execute path, in-worker
(no HTTP), tied to the notebook's **mounted per-student Drive** under our
**SW-disabled SAB-only** configuration. Survives every JupyterLite/Pyodide/Python
version bump, so it's our integration, not upstream.
