# Kernel boot cost, and loading packages on demand

Every xeus kernel boot installs its **entire** environment before it runs a line
of user code: fetch ~50 conda tarballs, untar each into the emscripten FS, then
`dlopen` the shared libraries. There is no partial mode upstream and no runtime
`pip`, because the editor's CSP is `connect-src 'self'`.

That cost is paid by three consumers, each on a student's critical path:

| consumer | boots | ours? |
|---|---|---|
| the JupyterLite editor | `@jupyterlite/xeus-extension` | no — vendored bundle |
| browser grading | `xeus-kernel-shared.js` | yes |
| the pattern-family editor's auto-compute | `python-eval-worker.js` | yes |

This note records what that costs, measured, and what can be done about it.

## What the environment actually weighs

Sizes are the vendored `kernel_packages/` tarballs; the closure is taken over
`empack_env_meta.json`'s own `depends` arrays.

```
chickadee-python   48 packages   61.1 MB
  closure(xeus-python) — the bare kernel        28 pkgs    9.7 MB
  everything else — the data-science set        20 pkgs   51.4 MB   (84%)

chickadee-r        51 packages   62.1 MB
  closure(xeus-r) — the bare kernel             28 pkgs   39.9 MB
  everything else — the tidyverse set           23 pkgs   22.2 MB   (36%)
```

Marginal cost of each package the Python env file declares, over the bare
kernel. These **overlap** — scipy pulls openblas and numpy, statsmodels pulls
scipy and pandas — so they are not additive:

```
+numpy         3.3 MB    +pandas       8.8 MB    +pillow        1.8 MB
+matplotlib   15.7 MB    +scipy       30.2 MB    +statsmodels  39.6 MB
```

`openblas` alone is 16 MB, and **only scipy needs it** — numpy does not. So
scipy costs ~27 MB of boot payload for a package that imports in 0.09 s and that
Chickadee's generated tests never touch.

R's optional share is smaller — 36% against Python's 84% — because `r-base`
alone is 25 MB of unavoidable kernel. But **`r-stringi` (14 MB) is not part of
the bare kernel**; it arrives with `stringr`/`tidyr`. Getting that backwards is
what initially made the R saving look not worth having, and the marginal costs
are what matter:

```
+r-dplyr    2.4 MB (7 pkgs)     +r-tibble   0.8 MB (3)
+r-tidyr   18.6 MB (12)         +r-purrr    0.7 MB (2)
+r-readr    4.7 MB (16)         +r-forcats  1.4 MB (5)
+r-stringr 14.7 MB (3)          all seven  22.2 MB (23)
```

So a dplyr-only assignment installs 2.4 MB rather than all 22.2 MB, and a lab
that stays in base R installs none of it.

## What that costs in wall-clock

Booting the Python kernel with progressively larger subsets, Chromium,
3 runs each, fresh browser context per run so the HTTP cache never warms
across scenarios:

| boot | packages | payload | median | range |
|---|---|---|---|---|
| full env | 48/48 | 61 MB | **8604 ms** | 7129–9168 |
| kernel only | 28/48 | 9.7 MB | **4822 ms** | 4739–4855 |
| + numpy | 29/48 | 13 MB | 4839 ms | 4756–4933 |
| + pandas | 34/48 | 18.5 MB | 5353 ms | 5307–6143 |
| + matplotlib | 44/48 | 35 MB | 6092 ms | 5806–14622 |

**These numbers are from a local disk.** They therefore measure *install* cost —
untar, FS write, `dlopen` — with download time near zero. Two things follow:

- The saving is not a caching artifact. A student whose cache is fully warm
  still pays the ~3.8 s gap between the full env and a bare kernel, because the
  work is untarring, not fetching.
- Over a real network the gap is **larger** than this table shows, since the
  51 MB of optional packages also has to arrive.

Dropping just scipy and statsmodels from the boot takes 48 → 44 packages and
8.6 s → 6.1 s, a 30% cut, and ~26 MB less to download.

## Packages can be added to a live kernel

The load-bearing question is whether the boot is a one-shot. It is not.
`bootstrapEmpackPackedEnvironment` is additive against an already-started
`Module`: called a second time with a different package list it installs those
packages into the running kernel's filesystem, and `loadSharedLibs` — both
already exported from the vendored mambajs slice — `dlopen`s any native
extensions they carry.

Probed against a real kernel in Chromium (a subset boot, then two incremental
adds, asserting the package is genuinely absent beforehand and computes
afterwards):

```
booted with a strict subset ......................... 28/48 packages
numpy is genuinely absent before the add ............ ModuleNotFoundError
the incremental add reports packages ................ [numpy], 1 shared lib
numpy imports and computes after the add ............ numpy 2.5.1 -> 6
a second add layers on top .......................... [pandas, +4 deps], 5 shared libs
pandas imports and computes after the second add .... pandas 3.0.5 -> 6

boot(subset) = 4830 ms    add(numpy) = 242 ms    add(pandas) = 696 ms
```

So an add costs a few hundred milliseconds and needs no new vendored code. Only
a real kernel can prove this — the Node suite in `Tests/BrowserRunnerJSTests`
runs against a fake worker and never boots one.

## What shipped

### Browser grading: failure-driven, not predicted

The obvious design — have the server compute the package set from the
assignment's test-script imports and boot exactly that — does not work, and the
reason is worth writing down. Under browser grading the test script imports the
*student's* module, so the student's own imports run too. The server cannot know
those. Predicting the set means being wrong for the one student who imported
something the tests did not.

The kernel answers instead. `python-grading-worker.js` boots
`bootSeeds: ['xeus-python']` — the interpreter and the kernel, nothing from the
data-science half — runs the script, and if it fails with
`ModuleNotFoundError: No module named 'X'`, resolves X to its owning package,
installs that package's closure into the live kernel, and re-runs *that script*.
It costs nothing when it does not happen and one wasted script run plus
~250–700 ms when it does, and it cannot be wrong about what is missing, because
the kernel is the one reporting it.

Bounded by construction: each pass must install at least one new package, so the
set of installable packages strictly shrinks and the loop terminates (capped at
4 regardless). A module the environment does not have resolves to null and the
original `ModuleNotFoundError` stands byte-for-byte.

The mapping comes from `moduleOwners` in `importable-modules.json`, a by-product
of the scan `derive-kernel-modules.py` already does — the tarball being read *is*
the answer, so it cannot drift from the shipped bytes. Names are import names,
not distribution names: `PIL` → `pillow`, `matplotlib` → `matplotlib-base`.

`KernelImportGuard` already refuses to save a browser-graded script importing
something the env cannot supply, so this path is in practice only exercised by
*student* imports.

**Install from the environment prefix, not the workspace.** By the time a script
triggers an install the kernel has `chdir`'d into `/chickadee_work_*`, and the
unpacker resolves paths relative to cwd — installing from there fails inside the
vendored bundle with a bare `Error` and no message. `addPackages` chdirs to `/`
and restores afterwards. This is invisible to every unit test and only appears in
a real kernel; `Tools/browser-grading-smoke` is what caught it.

### R does the same, and gains more than expected

`r-grading-worker.js` boots `xeus-r` alone and installs on the same failure-driven
loop — shared with Python in `xeus-kernel-shared.js`, because a retry that
terminates for one language and spins for the other would be an expensive way to
discover they had drifted. R words the failure identically for `library()`,
`require()` and `pkg::fn` (the latter two route through `loadNamespace()`), so
one pattern covers every way a script can name a package:
`there is no package called 'dplyr'`.

Re-running a script after each install is cheap despite R's very expensive first
attach, because attaching a package already attached in this session is instant:
a re-run pays only for the newly installed one.

Measured on the smoke's fixture, which attaches **and exercises** all seven
tidyverse packages, Chromium, same harness before and after:

| | boot | that script |
|---|---|---|
| full env at boot | 5.1–10 s | **62 006 ms** |
| bare kernel + on demand | 3.9–4.0 s | **5 621–6 815 ms** |

Reproducible across three runs, and the script calls into `dplyr`, `tidyr`,
`readr`, `stringr`, `tibble`, `purrr` and `forcats` rather than merely attaching
them, so it is not a green attach hiding a broken package.

**The mechanism for the ~10× is not established.** The plausible one is that
`addPackages` runs `loadSharedLibs` over exactly the newly installed subset at
install time, so the shared objects are already resolved when `library()` runs,
whereas the full-env boot left that work to R's own lazy path at first attach
(where it measured 26 s for `dplyr`). That is inference, not a measurement, and
it is recorded here as such rather than asserted.

### The eval worker keeps the full environment

`python-eval-worker.js` evaluates instructor expressions for pattern-family
auto-compute. It was the obvious second candidate and is deliberately left
alone: its smoke asserts that *every package the environment declares* actually
imports, which is a real guard against a well-formed-but-broken env (the urllib3
incident), and subsetting the boot would gut it. It is also authoring-time
rather than on a student's critical path.

### The editor: deliberately not in this slice

The editor is the highest-traffic consumer and the hardest, because it boots
through the vendored `@jupyterlite/xeus-extension` rather than our own code.
Subsetting it means either patching that extension (another entry in the
sha-cascade the build already manages) or installing a `sys.meta_path` finder in
the kernel that calls back into JS on a miss — elegant, but an async fetch
behind a synchronous import.

Neither is a natural extension of the grading work, and the editor is where a
wrong answer is most visible. It should be decided on its own.

## Caching

Browser HTTP caches are partitioned per top-level site and per user profile, so
there is no cross-user sharing to arrange and no shared read-only mount that
would help: the bytes are already static files on disk, served by
`EditorAssetFastPathMiddleware`, and the operating system page cache already
keeps one copy for all users server-side. The per-user cost is a browser-side
property we cannot pool.

What *is* done: the `kernel_packages/` subtrees are on
`EditorAssetFastPathMiddleware`, so those requests no longer each pay a Fluent
session lookup on the full middleware chain.

Deliberately the `kernel_packages/` subtree rather than `/jupyterlite/xeus/`
wholesale. The wider prefix also captures `kernels.json` and each
`<env>/<kernel>/kernel.json`, which the editor fetches during app **startup**,
before any kernel exists — short-circuiting those skips the cache and isolation
middlewares for the requests that bring the app up.
`kernelStartupJSONStaysOnTheNormalChain` asserts that in both directions so a
well-meaning prefix widening fails in CI.

Still open: those files are stamped `no-cache`, so a warm boot issues ~50
conditional GETs. Every tarball but one is a pristine upstream conda artifact
under a `name-version-build` filename, immutable by conda convention; the sole
exception is `pyodide-http`, which `patch-xeus-python-http.py` rewrites in place
under the same name. Giving that one a content-addressed filename would make the
whole tree safe to cache immutably — `filename_stem` is unused by mambajs, only
`filename` is read, so the rename is confined to the patch script and
`empack_env_meta.json`.

Keep that win in proportion, though: ~50 conditional GETs returning 304,
multiplexed over one HTTP/2 connection. It removes latency, not bytes, and does
nothing for the install cost that dominates the table above — which is why
subsetting the boot was the work worth doing first.
