# JupyterLite and the vendored kernels

The embedded editor, the xeus kernel environments, and the browser libraries
that Chickadee vendors. CLAUDE.md keeps the rules and points here for the
measurements and the history behind them. The runbook for a new kernel is
[adding-a-xeus-kernel.md](adding-a-xeus-kernel.md).

Chickadee embeds a full JupyterLite instance at `Public/jupyterlite/`. This
enables in-browser notebook editing for both students (submit) and instructors
(create/validate assignments).

Source-of-truth config lives in `Tools/jupyterlite/`. Rebuild:

```bash
scripts/setup-jupyterlite.sh
scripts/build-jupyterlite.sh
```

`Public/jupyterlite` is generated output and is checked in; rebuild only when
updating kernel versions or config.

**Every vendored kernel is a xeus kernel, one env each.**
`Tools/jupyterlite/environment-python.yml`, `environment-r.yml`,
`environment-lua.yml` and `environment-octave.yml` declare one
emscripten-forge environment each, yielding `xpython` (Python, xeus-python),
`xr` (R, xeus-r), `xlua` (Lua, xeus-lua) and `xoctave` (Octave, xeus-octave);
`jupyter lite build` compiles them all into
`Public/jupyterlite/xeus/`. They are **separate envs on purpose** — a kernel
fetches its whole env at boot, so a shared env makes every Python boot pull
r-base and every R boot pull numpy/pandas/matplotlib (slow enough to time out
the editor probes). `check-xeus-vendored.sh` asserts they stay distinct. Python moved
off the Pyodide kernel in the 0.5 series, so the editor runs one kernel
technology for every language. Notebook metadata is normalized to those names by
`normalizeNotebookForJupyterLite` (`NotebookContentHelpers.swift`) — for every
vendored kernel. A Lua notebook resolves to `xlua` and extracts through the
same marker-emitting RunnerCore extractor R uses — vendoring a kernel puts it
in the editor's picker, so a language that can be authored must be one that
can be graded.

**One place still enumerates the kernels rather than discovering them, and it
fails open for one it has never heard of:** the `chickadee-*` glob in
`build-jupyterlite.sh`, which decides who gets a module index. It does not error
— you simply get a kernel nothing checks. Its twin is closed: `expected_language`
in `check-xeus-vendored.sh` derives the expected set from each language's
`editorSupport.notebookKernel(kernelName:)`, so a kernel is guarded the day its
descriptor names it.

**Deriving it did not make it safe.** That derivation reads Swift with a regex
and paired language to kernel by line PROXIMITY, so when #1330 hoisted the
descriptors into their own `static let`s it went silently partial — one kernel,
mapped to the wrong language — and `main` was red for five releases while every
PR showed green, because the workflow's path filter reported the job green when
it skipped it and only `push` counted as relevant. Three rules came out of it: a
derivation must assert its own **completeness** (only an empty one used to fail,
and a partial one is indistinguishable from a correct one); read the mapping the
compiler already forces to be exhaustive rather than inferring one from
proximity; and **a guard whose answer depends on the event it runs under is not
a guard**. `docs/adding-a-xeus-kernel.md` is the runbook.

The channel is **`emscripten-forge-4x`**. The older `emscripten-forge-dev` alias
serves the 3x (emscripten 3.x ABI) channel, which stopped receiving builds of
any kind on 2026-04-09 — frozen, not merely older. Do not point the env file
back at it.

Anything a student imports must be baked into the matching env: the editor's CSP is
`connect-src 'self'`, so there is no runtime pip/piplite escape hatch and a
missing package is an ImportError with no recovery. The Python set is currently
numpy / pandas / matplotlib / scipy / sympy / scikit-learn / statsmodels / PIL;
the R side is the tidyverse core (dplyr, tidyr, readr, stringr, tibble, purrr,
forcats).

**The kernel environments are checked at authoring time, and the check reads
the VENDORED bytes, never the environment YAML.**
Since browser grading moved onto this env, saving a browser-graded `.py` whose
imports the kernel cannot satisfy is rejected at the write
(`KernelImportGuard`, wired into the web create/update handlers, `PUT /suite`,
and MCP `author_script`) — which matters because instructor validation is graded
by the *native* worker on a full CPython, so such a test validates green and then
fails for the first student who submits. The available set comes from
`importable-modules.json`, derived from `kernel_packages/*.tar.gz` by
`scripts/derive-kernel-modules.py`. Adding a name to the env file changes
nothing until `build-jupyterlite.sh` runs, so a check derived from the env file
would accept imports the shipped kernel cannot serve — the exact failure it
exists to prevent. Reading the tarballs also means there is no
distribution-name-to-import-name table to maintain. The check applies to
browser-graded assignments only (worker grading runs a real interpreter) and
resolves every ambiguity toward reporting nothing, since a false positive blocks
an instructor from saving with no self-service fix. `KernelImportGuard` dispatches on file
extension; R is scanned by `RLibraryScanner` for `library()`/`require()`/`::`.
It declines `.lua` on purpose: emscripten-forge ships no Lua library packages,
so the `chickadee-lua` inventory is empty and a guard against it would reject
every `require`, starting with the `require("test_runtime")` that opens every
generated Lua test.

**A kernel env has TWO costs, and they fall on different people. Be sparing.**
*Boot* — fetching and mounting the whole env — is paid by everyone on every
notebook open and every browser-graded submission, whether or not they touch the
package. *Import/attach* is paid only by a script that uses it, but is charged
against the default **10-second** per-test limit. Measured in real kernels:

| | R | Python |
|---|---|---|
| boot | ~5-10s (52-91 MB; single runs, noisy) | ~8-10s (85 MB) |
| worst single import | `ggplot2` **193s**, `lubridate` 32s | `scikit-learn` **10.8s**, `sympy` 5.9s, `pandas` 4.8s |

Attach costs are **not independent**: the R tidyverse shares a dependency graph,
so whichever package attaches first pays for all of it (~26s cold, ~58s for the
set) and the rest come cheap. `ggplot2` and `lubridate` are excluded from the
default R env on that basis despite solving fine; `scikit-learn` already exceeds
the default limit in Python. `Tools/browser-grading-smoke` prints per-package
timings and asserts every declared package actually loads — measure there rather
than reasoning about package counts, and treat single boot numbers as a trend
only.

Building the kernels needs **micromamba on PATH plus network to
repo.prefix.dev**. This was long documented as something *CI cannot do*, and
that was simply **wrong** — a hosted runner has unrestricted network and
micromamba is a single ~7 MB download. Re-vendoring is now a workflow:
`.github/workflows/revendor-kernels.yml`, on demand or when a PR changes an
environment file. It does not run unattended, because the output is ~100 MB of
content-hashed binary assets and an automatic rebuild would bury unrelated work
in unreviewable diffs.

That false belief had a cost worth remembering. Adding a name to
`environment-*.yml` changes nothing until the kernel is rebuilt, so
"maintainer-machine only" meant env files drifted from the shipped bytes:
scipy/sympy/scikit-learn/statsmodels were declared, announced in a changelog,
and absent from the kernel — an unrecoverable `ImportError` waiting for the
first student who imported one. Every existing guard compared the vendored tree
to *itself*, so none of them could see it.
`scripts/check-env-vendored-sync.sh` is the one that compares **declared intent
to shipped bytes**, costs two file reads, and fails the PR pointing at the
workflow.

The committed `Public/jupyterlite/xeus/` bytes remain authoritative for every
other job (`scripts/check-xeus-vendored.sh` guards their integrity; the
reproducibility check excludes that path) — the rebuild is a deliberate act, not
part of the normal build.

**The vendored `pyodide-http` is patched, and must stay patched.**
`xeus-python → xeus-python-shell-lite → pyodide-http` is an unavoidable
dependency chain, and `pyodide-http` selects a Pyodide-specific streaming
implementation whenever `crossOriginIsolated` is true. It is not pyjs-compatible,
so un-patched the kernel never leaves `kernel_starting` on an isolated engine and
the editor sits on "Kernel Connecting" forever.
`scripts/patch-xeus-python-http.py` (run from `build-jupyterlite.sh`, asserted by
`check-xeus-vendored.sh`) forces the library's own XHR fallback on every engine.
The guard matters more than usual because this failure is invisible in the
JupyterLite REPL (no Drive-backed file, so no HTTP call) *and* on WebKit (not
isolated, so it takes the fallback anyway) — only isolated engines hit it.

**Synchronous stdin uses a different transport per engine — check the
middleware, not the static config.** `input()` works on both, but not the same
way, and reading `Tools/jupyterlite/jupyter-lite.json` alone gives the wrong
answer:

| engine | isolation | stdin transport |
|---|---|---|
| Chromium / Firefox | isolated (`COEPMiddleware`) | `SharedArrayBuffer`; service worker disabled as redundant |
| WebKit (Safari) | **non-isolated on purpose** | **service worker**, which `JupyterLiteConfigFlagMiddleware` re-enables *per request* for this engine |

So "the service worker is disabled" is true of Chromium only. Both paths are
covered by a blocking `SMOKE_KERNEL=xpython` probe in `editor-smoke.yml`, run on
both engines because the transports fail independently.


## Vendored browser libraries

jszip and CodeMirror are vendored under `Public/` rather than pulled from
third-party CDNs at runtime, so student / instructor IPs aren't leaked to
`cdn.jsdelivr.net` and `esm.sh` on every page load (FIPPA / PIPEDA concern
surfaced in the v0.4.171 audit). The editor kernels are vendored under
`Public/jupyterlite/xeus/` for the same reason.

```
Public/vendor/jszip.min.js       — jszip the browser runner uses for zip extraction
Public/vendor/codemirror.js      — bundled CodeMirror 6 ESM
Public/vendor/xeus-bootstrap.js  — mambajs slice that boots a xeus kernel
Public/vendor/xeus-unpack.wasm   — untarjs unpacker the bootstrap drives
```

**Pyodide is gone (v0.5.19).** `Public/pyodide` was ~465 MB of vendored bytes;
`check-pyodide-parity.sh`, `add-pyodide-extras.py`,
`Tools/vendor/pyodide-extra-packages.json`, `patch-pyodide-kernel.py`, the
nb_mypy/astor wheels and the `jupyterlite-pyodide-kernel` federated extension
went with it. Every editor kernel and every browser grader is xeus.
`verify-jupyterlite.sh` fails if any `pyodide` federated extension or plugin
setting reappears, because re-adding the kernel means re-vendoring that payload
and restoring its CSP allowances.

**Two things the retirement did NOT deliver, both measured:**

- **`'unsafe-eval'` cannot be narrowed to `'wasm-unsafe-eval'`.** The plan
  assumed Pyodide was the only thing needing it. It is not: with Pyodide fully
  removed, `wasm-unsafe-eval` leaves JupyterLab unable to activate its plugins —
  the editor loads, reports `crossOriginIsolated`, fetches both kernel manifests,
  then never renders a console. Restoring `'unsafe-eval'` with no other change
  makes the same smoke pass. JupyterLab compiles JSON-schema validators at run
  time. Do not retry without a plan for that.
- **Kernel packages still revalidate on every boot.** They are `no-cache`
  because conda filenames are stable across an in-place patch
  (`patch-xeus-python-http.py` rewrites bytes under the same name), so immutable
  caching would pin an unpatched copy — the #574 failure class. Making them
  immutable needs content-addressed filenames, because
  `empackLockToMambajsLock` builds package URLs as `pkgRootUrl + '/' + filename`
  inside the vendored bundle, leaving no seam for a `?v=` cache-buster.
  `/jupyterlite/xeus/` IS now on `EditorAssetFastPathMiddleware`, so those ~50
  revalidations per boot no longer each cost a Fluent session lookup.

**The waitAsync polyfill patch covers every extension, not one.**
`scripts/patch-waitasync-worker.py` (was `patch-pyodide-waitasync-worker.py`)
rewrites the `Atomics.waitAsync` polyfill's helper worker from a CSP-blocked
`data:` URL to a `blob:` one. It was scoped to the pyodide-kernel extension —
and when Pyodide was retired it turned out the **xeus** extension shipped the
identical un-patched polyfill, in the kernel Chickadee actually runs, for every
language. A per-extension scope is how that went unseen for two releases; the
glob and the matching `verify-jupyterlite.sh` assertion are how it stays seen.
