# In-browser R notebook kernel — spike findings (2026-07)

Status: **spike complete, validated end-to-end.** No production wiring yet.
This note records what was tested, what works, what does not, the reproducible
recipe, and the phased plan to ship R notebook support.

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
- **`xeus-python` is NOT ready to replace Pyodide.** On this exact stack it
  fails to boot (version skew — details below), so Python stays on Pyodide.
- **One open risk: Safari / iPad.** xeus hard-requires SharedArrayBuffer with no
  fallback; we currently serve WebKit non-isolated on purpose. Needs a
  real-device test.

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
| **xeus-python** | `xeus-python 0.17.8` / xeus 5.2.8 | ✅ | ❌ | `generic_type: type "XKernel" is already registered` → kernel socket reset; reproduced solo AND combined |
| **Pyodide-Python** | `jupyterlite-pyodide-kernel 0.8.1` | ✅ | ✅ Py 3.14.2 | our vendored `Public/pyodide`, unchanged |
| **Pyodide + xeus-r in one site** | both of the above | ✅ | ✅ both | no `XKernel` collision — Pyodide is not a xeus kernel |

### Why xeus-r, not WebR

`jupyterlite-webr` (the r-wasm WebR kernel) is capped at **0.6.0** (June 2025),
which requires `jupyterlite-core<0.7`. We pin `0.8.1`. No release targeting core
0.7+/0.8 exists. That is the permanent form of the #77 blocker for that package.

`jupyterlite-xeus 5.0.0` requires `jupyterlite-core >=0.7,<0.9` — compatible with
our pin — and builds the R kernel from the `xeus-r` emscripten-forge package. Same
end result (R-in-WASM in the browser), maintained, current.

### Why xeus-python is not viable yet

`jupyterlite-xeus 5.0.0`'s JS loader is aligned to the **xeus 6.x** ABI (which
`xeus-r 0.10.0` matches). The emscripten-forge `xeus-python 0.17.8` is still built
against **xeus 5.2.8**, so its WASM double-registers embind types
(`type "XKernel" is already registered`) and the kernel dies during boot.
Reproduced both solo and alongside R. This is upstream version skew, likely
resolved when emscripten-forge rebuilds `xeus-python` against xeus 6 — but it is
**not turnkey today**, so a wholesale Pyodide→xeus switch for Python is deferred.

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

### Phase 3 — Python → xeus unification (optional, later)

Only if we want one kernel framework for everything. Gated on (1) emscripten-forge
shipping a `xeus-python` aligned to xeus 6.x (today it fails to boot), and (2) a
passing Safari/iPad SAB test. Do not couple this to shipping R.

---

## Version matrix tested

| Component | Version |
|---|---|
| jupyterlite-core / jupyterlite | 0.8.1 |
| jupyterlite-xeus | 5.0.0 |
| jupyterlite-pyodide-kernel | 0.8.1 |
| xeus-r | 0.10.0 (xeus 6.0.3), R 4.5.1 |
| xeus-python (failed) | 0.17.8 (xeus 5.2.8), Python 3.13.1 |
| Pyodide (vendored) | Public/pyodide (Python 3.14.2) |
| empack | 6.0.1 |
| micromamba | 2.8.1 |

Cross-origin isolation for the notebook editor already ships (the old #77
COOP/COEP blocker is resolved) — `COEPMiddleware` sets isolation on
`/testsetups/:id/notebook` and `/validate`.
