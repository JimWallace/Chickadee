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
`normalizeNotebookForJupyterLite` (`NotebookContent.swift`) — for every
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
environment file. It never commits onto unrelated work, because the output is
~100 MB of content-hashed binary assets. When the weekly
`kernel-currency.yml` finds the kernels behind their channels, it dispatches
the workflow in publish mode: a rebuild from `main` on its own
`kernels/revendor-*` branch, opened as an auto-merging pull request whose CI
tests the new kernels. Publishing needs the `RELEASE_TOKEN` secret; the header
of the workflow says why.

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
covered by a blocking `SMOKE_KERNEL=xpython` probe in the `smoke` job of
`browser-probes.yml`, run on
both engines because the transports fail independently.


## What a kernel boot downloads

A student's first editor boot downloads about 50–60 MB for Python: the
`kernel_packages/` tarballs (~48 MB gzipped, scipy, openblas, matplotlib-base,
pandas and statsmodels the largest), `bin/xpython.wasm` (15 MB, 4.4 MB as
brotli) and the JupyterLite shell. A class of 150 that opens notebooks at once
pulls 8–9 GB. Every one of those files is cached afterwards (the tarballs
immutably for a year), so the load falls on a course's first week, on a
re-vendor (new names), on cache eviction (Safari evicts readily) and on lab
machines that wipe profiles. A third-party CDN is ruled out (see "Vendored
browser libraries" below).

**`KernelAssetList` names the boot files, from the kernel's own metadata.**
It reads `<kernel>/kernel.json` and `empack_env_meta.json` at server boot and
lists the loader, the binary, each `metadata.shared` library and every package,
as the URLs the kernel requests, with a version that changes when any file
does. The pages below read it from a data attribute. A checkout without the
vendored bytes has no list, and the pages then render neither feature.

**Cold loads are measured, per page load (`asset_load` breadcrumbs).**
`Public/kernel-asset-telemetry.js` sends one per boot through
`/api/v1/client-diagnostics`, and `get_browser_diagnostics` reports
`assetLoads` (per source) and `assetLoadsByDay`: loads, cold loads, the cold
share, bytes over the network versus from the cache, and boot time p50 and p90.

| source | context | how it knows |
|---|---|---|
| `editor` | notebook page | The kernel fetches from a worker inside the JupyterLite iframe, and resource timing entries stay in the context that fetched them, so the page cannot read them. It asks the HTTP cache instead: a `cache: 'only-if-cached'` request per file before the iframe mounts (never the network), and again for the missing files once the kernel is idle, which reads their size. The iframe collector sends the shell's own timings (`shell_assets`) just before `kernel_idle`. `boot_ms` is `kernel_idle`'s `elapsed_ms`. An engine that does not honour `only-if-cached` reports `probe=unsupported` and no `cold`. |
| `grading` | browser grading worker | Chickadee's own worker reads its resource timings and returns them with the `<lang>_kernel_booted` phase. Submit path only. |
| `prewarm` | dashboard | The warm below, from the page's own timings. |

A load is cold when any kernel file came over the network. A revalidation (a
304 for the `no-cache` binaries) counts as cached. The breadcrumbs share the
endpoint's per-user, per-assignment, per-source hourly limit (for `asset_load`
the kernel environment is part of the key too), so the numbers count the first
load of each hour per assignment. That over-counts cold loads against a
per-request rate, and is the load that matters for a class arriving at once.
`asset_load` rows stay out of `bySource` and `recentSamples`, which are for
failures.

**The dashboard warms the cache before class (`Public/kernel-prewarm.js`).**
When the student dashboard lists an open notebook assignment, it renders the
kernel's list on the warm script. Browser-graded or not, opening the notebook
boots the editor's kernel, and that boot is the download. After the page loads
and goes idle, plus 5 seconds, the script fetches one file at a time at low
priority, reads each body to the end and discards it. It skips a
`saveData` or 2G connection and a kernel this browser already warmed at its
current version in the last 7 days (`localStorage`, `ck-kernel-warm:<env>`,
holding the version and the time). The marker records that the files arrived,
not that the browser still has them, so it lapses: a re-warm of cached files
downloads nothing for the immutable tarballs and costs a 304 for the rest. A failure leaves the
version unmarked and the page unchanged; the kernel then downloads what it
needs, as before. Leaving the page cancels the warm, so at most one file is
fetched twice when a student opens a notebook mid-warm.

The warm lands in the cache entry the kernel reads, and three things were
checked to make it so:

- **The same request.** Same URL, `GET`, `credentials: 'same-origin'` (the
  mambajs `fetch` and emscripten's both send cookies), and the browser chooses
  the same `Accept-Encoding`, so the brotli copy matches.
- **The same cache partition.** Engines key the HTTP cache by top-level site;
  the dashboard, the notebook page, its same-origin iframe and the kernel worker
  all share one. Cross-origin isolation is not part of the key, and a
  same-origin response passes `require-corp` without a CORP header (the
  tarballs carry `same-origin` CORP from the fast path anyway), so a response
  cached by the non-isolated dashboard is usable on the isolated page.
- **The WebKit service worker passes through.** `JupyterLiteConfigFlagMiddleware`
  turns the JupyterLite service worker on for WebKit, but
  `enableServiceWorkerCache` is unset, so its fetch handler calls `fetch()`
  and never answers from its own Cache Storage. The HTTP cache serves it.

**Only what an assignment needs: grading does, the editor does not yet.**
Browser grading already boots a bare kernel and adds packages on demand. The
editor still loads the whole environment, so the warm warms the whole
environment too. The measured design for the editor, and why it did not ship
here, is in [kernel-boot-cost.md](kernel-boot-cost.md) §"The editor".

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
- **Kernel packages revalidated on every boot. They do not now (#2544).**
  They were `no-cache` because the build patched a package in place under its
  upstream name. Now a tarball that the build rewrites carries the hash of its
  own bytes in its name (`patch-xeus-python-http.py`, checked by
  `check-xeus-vendored.sh` section 9). So each name maps to one set of bytes,
  and the tarballs are cached immutably for a year:
  `EditorAssetFastPathMiddleware.isImmutableKernelPackage` in the app, and the
  `kernel_packages/` location in `deploy/nginx.conf` on a systemd host. A new
  version arrives under a new name through `empack_env_meta.json`, which stays
  `no-cache`.
- **Kernel packages hold no build-only files.** A kernel unpacks every package
  into browser memory at boot. `scripts/prune-kernel-packages.py` (run from
  `build-jupyterlite.sh`) removes what no kernel reads at run time: static
  `.a` archives, top-level `include/`, pkg-config and CMake files,
  `share/man` and `share/doc`, CPython's `lib/python3.X/test/`, and the
  second copy of each kernel shared library. The xeus loader fetches those
  libraries from the kernel directory (`metadata.shared` in `kernel.json`,
  plus `lib/libxeus.so`), never from the unpacked package. Unpacked, this
  removed about 152 MB of 305 MB from Octave, 50 of 64 from Lua, 48 of 204
  from Python and 13 of 123 from R. Each archive it changes gets a
  content-hash name, as in the next rule. `check-xeus-vendored.sh` section 10
  fails if a package still holds such a file.
- **Large kernel files go out as brotli copies made at image build.** The
  `kernel-assets` stage of the Dockerfile writes `<file>.br` (quality 9) beside
  each `.wasm`, `.js` and `.so` file over 64 KB under `xeus/`, outside
  `kernel_packages/`, with the original's mtime. `PrecompressedAssetMiddleware`
  serves the copy to a browser that accepts `br`, except for a `Range`
  request. Measured: `liboctinterp.so` 27.2 MB to 5.0 MB, `xpython.wasm`
  15.0 MB to 4.4 MB, `xoctave.js` 11.5 MB to 0.59 MB. Quality 11 is about 12%
  smaller again but took ~95 s for one file, against ~5 s. A checkout run
  without the image build has no copies and falls back to the next rule.
- **The kernel `.so` libraries are gzipped by the app.** An Octave boot loads
  `liboctave.so` and `liboctinterp.so` (about 52 MB) as separate files, and R
  loads `libR.so`. They are `application/octet-stream`, which no compression
  allowlist includes, so `KernelLibraryCompressionMiddleware` opts them in. A
  full `200` GET only: a `206` or a `HEAD` stays identity.

**The waitAsync polyfill patch covers every extension, not one.**
`scripts/patch-waitasync-worker.py` (was `patch-pyodide-waitasync-worker.py`)
rewrites the `Atomics.waitAsync` polyfill's helper worker from a CSP-blocked
`data:` URL to a `blob:` one. It was scoped to the pyodide-kernel extension —
and when Pyodide was retired it turned out the **xeus** extension shipped the
identical un-patched polyfill, in the kernel Chickadee actually runs, for every
language. A per-extension scope is how that went unseen for two releases; the
glob and the matching `verify-jupyterlite.sh` assertion are how it stays seen.
