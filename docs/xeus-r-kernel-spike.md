# In-browser R notebook kernel — spike findings (2026-07)

Status: **spike complete and fully shipped, including Phase 3.** Both editor
kernels are now xeus kernels built from one env
(`Tools/jupyterlite/environment-{python,r}.yml` → `xpython` + `xr`,
`Public/jupyterlite/xeus/kernels.json`), wired up in
`Sources/APIServer/Helpers/NotebookContentHelpers.swift`.
This note records what was tested, what works, what does not, the reproducible
recipe, and the phased plan that shipped R notebook support.

> **2026-08 update — Phase 3 is done, and the blocker below was resolved
> upstream in March 2026.** Two things changed since this spike was written:
>
> 1. **emscripten-forge split channels.** The `emscripten-forge-dev` URL this
>    document uses throughout now serves the **3x** (emscripten 3.x ABI)
>    channel, which received its last build of *any* package on **2026-04-09**.
>    It is frozen. The live channel is **`emscripten-forge-4x`**. Everything
>    below that reads "no xeus-6 xeus-python exists" was true of the frozen
>    channel and false of the live one.
> 2. **xeus-python has been built against xeus 6 since 0.18.1 (2026-03-09)**,
>    with a proper `run_exports` pin (`xeus >=6.0.2,<6.1`) — the supported
>    pairing this document said to wait for, not the unguarded 0.17.4 trick.
>    Shipped on **0.19.0 build 2** (`xeus >=6.0.5,<6.1`).
>
> Read the xeus-python sections below as history: the reasoning was correct at
> the time and the conclusion ("wait for a real xeus-6 build") is exactly what
> happened. See the "What actually shipped" section at the end for current
> state.

Tracker: issue #77 ("Add R submission support and WebR kernel support"). Part 1
(worker-graded R submissions) already shipped in PR #102. This spike covers the
deferred part 2 — an **in-browser R kernel** for the JupyterLite editor.

---

## TL;DR

- **An in-browser R kernel works on our current JupyterLite 0.8.1 stack**,
  proven end-to-end (build → boot → execute R) in headless Chromium under the
  cross-origin isolation we already send.
- **The winning path is `xeus-r` (via `jupyterlite-xeus`), not WebR.** The
  `jupyterlite-webr` package that blocked #77 is a dead end (see below); the
  live path is xeus / emscripten-forge.
- **R and Python coexist in one editor.** `jupyterlite-pyodide-kernel` (our
  existing Python kernel, using our vendored Pyodide) and `jupyterlite-xeus`
  (xeus-r) boot side by side in one deployment, both cross-origin isolated.
- **`xeus-python` on xeus 6 is possible but *unsupported* — not recommended.**
  The newest xeus-python (0.17.8) is ABI-pinned to xeus 5.2 (`xeus >=5.2.8,<5.3`
  — a conda `run_exports` bind, i.e. it is *compiled against* xeus 5.2) and
  crashes on jupyterlite-xeus's xeus-6 loader. Forcing `xeus >=6` falls back to
  the older, *unpinned* xeus-python **0.17.4** and runs it on xeus 6.0.3 — an
  ABI-unguarded pairing. It does execute (verified: values, error tracebacks,
  and rich HTML display all render), but **no xeus-python is actually built
  against xeus 6 yet**, so the xcomm-refactor surface (comms/widgets) and other
  protocol edges are untested. **Real Python unification waits for an upstream
  xeus-6 xeus-python.** Meanwhile ship R on xeus (fully supported — below) and
  keep Python on Pyodide.
- **One open risk: Safari / iPad.** xeus (R *and* Python) hard-requires
  SharedArrayBuffer with no fallback; we currently serve WebKit non-isolated on
  purpose. Needs a real-device test.

---

## Background: what already ships

Worker-graded R is done (#77 part 1 / PR #102) and is unaffected by this spike:

- `.r` / `.R` classification → `Rscript` dispatch —
  `Sources/RunnerCore/ScriptClassification.swift`, `Sources/Worker/ScriptInvocation.swift`.
- R test-runtime helper (`passed`/`failed`/`errored` → exit 0/1/2) injected into
  every job — `Sources/Worker/TestRuntimeSources.swift`, canonical
  `Tools/runner-support/test_runtime.R`.
- R-kernel notebook extraction (`.ipynb` → `.R`) — `Sources/Worker/NotebookExtractor.swift`,
  `Tools/runner-support/nb_to_r.py`.
- `r-base` installed in the runtime image — `Dockerfile`.

The **grading** story for R is therefore already covered by the authoritative
native worker. This spike is purely about the **editor** (authoring / previewing
R notebooks in the browser).

---

## What was tested, and the results

All builds were done in a throwaway venv against the exact pins in
`Tools/jupyterlite/requirements.txt` (`jupyterlite-core==0.8.1`). Boot tests ran
in headless Chromium (Playwright) against a static server sending
`Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp`.

| Kernel | package / bundled xeus | build | boot + execute | notes |
|---|---|---|---|---|
| **xeus-r** | `xeus-r 0.10.0` / xeus 6.0.3 | ✅ | ✅ R 4.5.1 | `crossOriginIsolated=true`, `mean`/`sd`/`summary()` correct |
| **xeus-python** (solver default) | `0.17.8` / xeus 5.2.8 | ✅ | ❌ | `type "XKernel" is already registered` — newest build is ABI-pinned to xeus 5.2, mismatches the xeus-6 loader |
| **xeus-python** (force `xeus >=6`) | `0.17.4` / xeus 6.0.3 | ✅ | ⚠️ runs | ABI-**unguarded**: 0.17.4 is xeus-5-era + unpinned. exec/error/rich-display verified, but **not built against xeus 6** — comms/widgets untested. Not for production |
| **Pyodide-Python** | `jupyterlite-pyodide-kernel 0.8.1` | ✅ | ✅ Py 3.14.2 | our vendored `Public/pyodide`, unchanged |
| **Pyodide + xeus-r in one site** | both of the above | ✅ | ✅ both | no `XKernel` collision — Pyodide is not a xeus kernel |

### Why xeus-r, not WebR

`jupyterlite-webr` (the r-wasm WebR kernel) is capped at **0.6.0** (June 2025),
which requires `jupyterlite-core<0.7`. We pin `0.8.1`. No release targeting core
0.7+/0.8 exists. That is the permanent form of the #77 blocker for that package.

`jupyterlite-xeus 5.0.0` requires `jupyterlite-core >=0.7,<0.9` — compatible with
our pin — and builds the R kernel from the `xeus-r` emscripten-forge package. Same
end result (R-in-WASM in the browser), maintained, current.

### xeus-python: runs on xeus 6, but the pairing is unsupported

The boot failure is real but its cause is precise. Left unconstrained, the solve
picks the *newest* `xeus-python` (0.17.8), whose pin `xeus >=5.2.8,<5.3` drags in
xeus 5.2.8 — ABI-incompatible with `jupyterlite-xeus 5.0.0`'s xeus-6 loader, so
its WASM double-registers embind types (`type "XKernel" is already registered`)
and the kernel dies at boot. Reproduced both solo and alongside R.

**Why that pin exists (this is the important part).** It is not a "we tried xeus 6
and reverted" decision — it is a conda **`run_exports`** ABI bind. xeus-python
0.17.5+ is *compiled against* xeus 5.2.x, and the build system auto-pins it to
that ABI (`>=5.2.x,<5.3`). The pin **is** the documented rationale, in enforced
form: this binary is linked to xeus 5.2. **No xeus-python has been built against
xeus 6 at all** — 0.17.8, the newest, is still xeus 5.2.8. xeus 6.0.0 is a major
release that refactored the **xcomm API** and changed `create_info_reply`, so a
xeus-5-era kernel on a xeus-6 core is a genuine mismatch.

**What the `xeus >=6` trick actually does.** It forces the solver onto the older,
*unpinned* `xeus-python 0.17.4` (a xeus-5-era build that predates the run_exports
guard) and runs it on xeus 6.0.3 — i.e. it **removes the guardrail, it does not
satisfy it.** Empirically the pairing survives more than a smoke test — value
output, error tracebacks, and rich HTML (DataFrame) display all render correctly
in headless Chromium — but the untested surface is exactly what xeus 6 changed
(comms/widgets, interactive output), and depending on an unpinned old build is
fragile against a re-solve. **Runs is not the same as supported.**

**Conclusion.** Do not ship Python-on-xeus on this pairing. The supported path is
to wait for emscripten-forge to publish a `xeus-python` built against xeus 6
(proper `run_exports` pin to 6), and keep Python on Pyodide until then. Note the
asymmetry: **`xeus-r 0.10.0` *is* built against xeus 6** (`xeus >=6.0.2,<6.1`), so
R-on-xeus is fully supported and unaffected by any of this.

### The Safari / iPad squeeze

The coexistence build loaded Pyodide via `coincident.worker.js` — the
SharedArrayBuffer/coincident transport. `Sources/APIServer/Middleware/COEPMiddleware.swift`
deliberately serves **WebKit non-isolated** because that transport deadlocks
Safari, and Pyodide has a service-worker fallback for non-isolated mode. xeus-r
has **no fallback** — it requires SAB, hence cross-origin isolation:

| Isolation on Safari | Pyodide-Python | xeus-R |
|---|---|---|
| Isolated (COEP on) | may deadlock (the reason we went non-isolated) | ✅ |
| Non-isolated (today) | ✅ (SW fallback) | ❌ (no SAB) |

On Chrome / Firefox both work isolated. Safari/iPad is the one unsettled
question and is only answerable on a real device. Options to evaluate:
isolate only R-assignment editor pages; treat R notebooks as desktop-only;
or re-test whether current Pyodide/coincident still deadlocks isolated Safari
(that finding may be stale).

---

## Reproducible recipe

Toolchain (in a throwaway venv; mirrors `Tools/jupyterlite/requirements.txt` plus
`jupyterlite-xeus`):

```
python3 -m venv .venv-xeus
.venv-xeus/bin/pip install "jupyterlite-core==0.8.1" "jupyterlite-xeus==5.0.0" "jupyterlite-pyodide-kernel==0.8.1"
```

`jupyterlite-xeus` needs **micromamba** to solve the emscripten-forge
environment. In the agent-proxy sandbox, GitHub release assets are blocked (403)
but the conda channel host is reachable, so fetch micromamba from micro.mamba.pm:

```
curl -fsSL "https://micro.mamba.pm/api/micromamba/linux-64/latest" -o mm.tar.bz2
tar -xj -f mm.tar.bz2 bin/micromamba
```

R kernel environment file (`environment.yml`):

```yaml
name: chickadee-r
channels:
  - https://repo.prefix.dev/emscripten-forge-dev
  - https://repo.prefix.dev/conda-forge
dependencies:
  - xeus-r
```

Unified R + Python on xeus 6 (one env, both kernels) — note the `xeus >=6` pin
that steers the solver off the incompatible newest xeus-python:

```yaml
name: chickadee-unified
channels:
  - https://repo.prefix.dev/emscripten-forge-dev
  - https://repo.prefix.dev/conda-forge
dependencies:
  - xeus >=6
  - xeus-python
  - xeus-r
  - numpy
  - pandas
```

To serve Python from our vendored Pyodide instead of the CDN (required under
COEP), add a `jupyter-lite.json` in the build dir:

```json
{
  "jupyter-config-data": {
    "defaultKernelName": "python",
    "litePluginSettings": {
      "@jupyterlite/pyodide-kernel-extension:kernel": {
        "pyodideUrl": "/pyodide/pyodide.mjs"
      }
    }
  }
}
```

Build (micromamba on PATH, proxy CA exported so micromamba can fetch through the
egress proxy):

```
export PATH="$PWD/bin:$PATH"
export MAMBA_EXE="$PWD/bin/micromamba"
export MAMBA_ROOT_PREFIX="$PWD/mamba-root"
export SSL_CERT_FILE=/root/.ccr/ca-bundle.crt
export REQUESTS_CA_BUNDLE=/root/.ccr/ca-bundle.crt
.venv-xeus/bin/jupyter lite build --XeusAddon.environment_file=environment.yml --output-dir site
```

Then vendor Pyodide same-origin and serve with cross-origin isolation. Point the
`/pyodide` path at the checked-in copy:

```
ln -sfn "$PWD/Public/pyodide" site/pyodide
```

The static server must send `Cross-Origin-Opener-Policy: same-origin`,
`Cross-Origin-Embedder-Policy: require-corp`, and
`Cross-Origin-Resource-Policy: cross-origin` on every response. The JupyterLite
REPL boots a kernel by name, so a headless smoke test navigates to
`repl/index.html?kernel=xr&code=<r>&execute=1` (and `?kernel=python` for Pyodide)
and scrapes the rendered output.

### Footprint

The vendored xeus-r payload (R 4.5.1 + xeus-r + IRkernel display stack) is
**~57 MB** (`kernel_packages` ~41 MB + `xr` wasm ~8 MB + `bin` ~8 MB), all
same-origin, checked in like `Public/pyodide` — no runtime CDN fetch (FIPPA
posture preserved). For comparison Pyodide is ~465 MB.

---

## Phased plan

### Phase 1 — R editor kernel (near-term, low risk)

Add xeus-r alongside the unchanged Pyodide Python path.

- **Build pipeline:** add a micromamba bootstrap + `environment.yml` step to
  `scripts/setup-jupyterlite.sh` (or a sibling `setup-xeus.sh`). CI needs the
  emscripten-forge (`repo.prefix.dev`) and conda-forge hosts reachable, plus
  micromamba from micro.mamba.pm.
- **Vendor** the ~57 MB xeus-r payload under `Public/` (checked in, same-origin),
  and add a verify/parity guard analogous to `scripts/check-pyodide-parity.sh`
  pinning the R kernel version.
- **Editor kernel-awareness:** route the notebook kernelspec by assignment
  language. De-Python `normalizeNotebookForJupyterLite` in
  `Sources/APIServer/Routes/TestSetupRoutes.swift` (it currently forces every
  kernelspec to Python — see the #77 discussion notes).
- **Isolation / CSP:** serve `/xeus/**` same-origin via the editor fast-path
  (`Sources/APIServer/Middleware/EditorAssetFastPathMiddleware.swift`), and make
  sure the R editor route gets COOP/COEP (`COEPMiddleware.swift`). Current CSP
  needs no additions for same-origin assets.
- **Settle Safari** (see risk above) before promising R notebooks to iPad users.

### Phase 2 — grading

Nothing to build. Worker-R already grades authoritatively. With web-based
grading being retired, no browser-side R grader (WebR or xeus) is needed —
**punt WebR-for-grading.**

### Phase 3 — Python → xeus unification (SHIPPED 2026-08)

Was: blocked until emscripten-forge shipped a `xeus-python` built against xeus 6.
That landed as **0.18.1 on 2026-03-09** (`xeus >=6.0.2,<6.1`, a real
`run_exports` pin — not the unguarded 0.17.4 workaround), on the
`emscripten-forge-4x` channel. See "What actually shipped" below.

---

## Version matrix tested

| Component | Version |
|---|---|
| jupyterlite-core / jupyterlite | 0.8.1 |
| jupyterlite-xeus | 5.0.0 |
| jupyterlite-pyodide-kernel | 0.8.1 |
| xeus-r | 0.10.0 (xeus 6.0.3), R 4.5.1 |
| xeus-python (solver default — fails to boot) | 0.17.8 (ABI-bound to xeus 5.2.8) |
| xeus-python (force `xeus >=6` — runs, unsupported) | 0.17.4 (xeus-5-era build on xeus 6.0.3), Python 3.13.1, numpy 2.4.4, pandas 3.0.2 |
| Pyodide (vendored) | Public/pyodide (Python 3.14.2) |
| empack | 6.0.1 |
| micromamba | 2.8.1 |

Cross-origin isolation for the notebook editor already ships (the old #77
COOP/COEP blocker is resolved) — `COEPMiddleware` sets isolation on
`/testsetups/:id/notebook` and `/validate`.

---

## What actually shipped (2026-08)

Two emscripten-forge environments — `Tools/jupyterlite/environment-python.yml`
and `environment-r.yml` — supply the two editor kernels, one each. `scripts/build-jupyterlite.sh` compiles them into
`Public/jupyterlite/xeus/` and they are committed like the rest of the bundle.

| Component | Version | Note |
|---|---|---|
| channel | `emscripten-forge-4x` | 3x / `emscripten-forge-dev` is frozen since 2026-04-09 |
| xeus | 6.0.5 | |
| xeus-python (`xpython`) | 0.19.0 | Python 3.13.1 — replaces the Pyodide editor kernel |
| xeus-r (`xr`) | 0.11.2 | R 4.5.3, up from xeus-r 0.10.0 / R 4.5.1 |
| Python packages | numpy 2.5.1, pandas 3.0.5, matplotlib 3.11.1 | fixed at build time |
| R packages | none beyond `xeus-r` | add `r-*` to the env as courses need them |

Payload: `Public/jupyterlite/xeus` is **96 MB** (was 57 MB for R alone); the
whole bundle is 181 MB. Pyodide (`Public/pyodide`, ~465 MB) is unchanged and
still serves browser grading and `/validate`.

### Verified

Headless Chromium against the vendored bytes, served cross-origin isolated:

- `xpython` boots, executes, and imports pandas + numpy; `matplotlib` renders.
- `xr` boots and executes; `R.version.string` reports 4.5.3.
- `crossOriginIsolated === true` in both cases, and **zero external network
  requests** during boot or execution — the FIPPA posture is intact.

### Two things this does NOT settle

**Safari / iPad is still the open question, and consolidation sharpened it.**
`COEPMiddleware` deliberately serves WebKit *non-isolated* because the
SharedArrayBuffer/`coincident` transport deadlocked Safari. xeus has no
non-SAB fallback. So on WebKit today:

| | before | after |
|---|---|---|
| Python | worked (Pyodide + service-worker fallback) | **no kernel** |
| R | already unavailable | unavailable |

Moving Python to xeus therefore converts a working Safari path into a broken
one. Nothing here changes `COEPMiddleware`, so that regression is live for any
WebKit user the moment a notebook's kernelspec says `xpython`. The fix is to
re-test whether current Pyodide/coincident still deadlocks isolated Safari —
the finding is from 2026 and may well be stale — and if it doesn't, drop the
WebKit exemption so every engine is isolated. That needs a real device.

**Editor and grader are no longer the same Python.** Authoring runs xeus-python
3.13; browser grading and `/validate` run Pyodide 3.14. The native worker is
still the authoritative grader, so this does not affect marks — but "it ran in
the editor" no longer implies "it runs in the browser runner".
