# Adding a xeus kernel

How to teach Chickadee a third in-browser language, and — more usefully — what
that actually costs.

## Read this first: two halves, very different sizes

The **browser substrate is language-agnostic** and adding a kernel to it is
genuinely small. `Public/xeus-kernel-shared.js` knows nothing about Python or R:
it boots a kernel, resolves a dependency closure, installs a subset, adds
packages to a live kernel on demand, drives one cell, and mounts a workspace.
Per language you supply a kernel spec, how to build a cell, how to read the
reply, and one regex.

**The language is not a plug-in.** `AssignmentLanguage` is threaded through ~98
references in ~32 files, and while most are generic or compiler-enforced, a
working language also needs new *artifacts*: a literal renderer, a pattern-family
renderer, a notebook-check renderer, a personalization driver and seed runtime, a
`test_runtime.<x>`, an extraction branch. Those are the feature, not overhead;
no seam removes them. [docs/language-handling-review.md](language-handling-review.md)
§4 has the full census, bucketed.

So: **you can have a language grading `.lua` scripts in the browser in a day, and
a language a course can actually be authored in is a much larger arc.** #1207's R
series is the yardstick for the second. This document takes you through the
first, and tells you honestly where the second begins.

## Which kernels exist

From `emscripten-forge-4x`, the channel `Tools/jupyterlite/environment-*.yml`
point at. Closure sizes are compressed and `emscripten-wasm32` only, so treat
them as a ranking rather than absolutes — the vendored R env measures 29.9 MB
this way and 62 MB unpacked on disk.

The **xeus ABI pin matters as much as the size.** Our envs are on `xeus 6.0.5`,
and each env solves independently, so a kernel on the xeus 5 line is not fatal —
but `Public/xeus-kernel-shared.js` mirrors one xeus generation's boot sequence
(`new mod.xkernel(argv)`, `get_server()`, `notify_listener`), so a 5.x kernel is
the one most likely to need substrate changes rather than just a spec.

| kernel | latest | pkgs | MB | xeus |
|---|---|---|---|---|
| xeus-javascript | 0.4.2 | 2 | 1.1 | **5.2.6** |
| xeus-sqlite | 0.10.0 | 2 | 2.1 | 6.0.2 |
| xeus-haskell | 0.3.0 | 2 | 3.0 | 6.0.5 |
| xeus-lua | 0.10.1 | 5 | 4.1 | 6.0.3 |
| xeus-ocaml | 0.2.8 | 2 | 12.4 | **5.2.6** |
| xeus-cpp | 0.10.0 | 5 | 24.1 | 6.0.3 |
| xeus-lfortran | 0.64.0 | 2 | 31.5 | 6.0.5 |
| xeus-octave | 0.7.0 | 4 | 66.9 | 6.0.2 |

Regenerate with:

```bash
curl -sSL "https://repo.prefix.dev/emscripten-forge-4x/emscripten-wasm32/repodata.json" -o /tmp/repodata.json
```

Pick the latest by **version**, not by build number — the channel carries newer
builds of older versions, and sorting on `build_number` silently selects a stale
one with a different xeus pin.

### Availability is not the same as working

Everything above builds for wasm32-emscripten, and `jupyterlite-xeus` will
compile any xeus kernel it can solve into the bundle — that is the same mechanism
that produces our two. What it does not tell you is whether the kernel *behaves*
once booted, and both of our data points needed per-kernel work that appeared
only in a real browser:

- Python: `pyodide-http` selects a Pyodide-specific streaming fetcher when the
  page is cross-origin isolated, and the kernel never finished starting until
  `patch-xeus-python-http.py` forced the XHR fallback.
- R: `quit()` and `commandArgs()` had to be masked so one `test_runtime.R` works
  under both the kernel and a real `Rscript`, and each script has to be wrapped
  in **one** top-level expression because xeus-lite yields to the JS event loop
  between top-level expressions and does not regain control for ~180 ms.

Budget for one of these. It will not be predictable from the manifest.

### Recommendation

**To test-drive the architecture: `xeus-lua`.** Small, on the xeus 6 line, and —
unlike SQL or JavaScript — it preserves Chickadee's grading model: files on disk,
a `require`-shaped import, a runtime helper library, and a script that either
completes or raises. A failure there is a real finding about the architecture
rather than a mismatch you would have predicted. Its near-absent package
ecosystem is a bonus: it exercises whether on-demand loading degrades gracefully
with nothing to load.

**To teach with: `xeus-cpp` is more viable than it looks, and the REPL is not the
problem.** It depends on `cppinterop` (CppInterOp, the Clang-REPL layer that
succeeded cling), so C++ genuinely is interactive there — and in any case
Chickadee does not need a REPL. We need "run this file, report an exit code",
which is what we already do for Python and R by wrapping a file in one cell.

The real question for C++ is the **grading contract**, not interactivity:

- Chickadee's model is "the test script imports the student's module". C++ has no
  import; a test would `#include` the student's source into the interpreter
  session. Workable, but a different shape, and it lands on `test_runtime.<x>`
  and `SubmissionNormalizer` rather than on the substrate.
- An interpreter is not a compiler. Code that only fails at link time, or that
  depends on separate compilation, behaves differently than under `gcc`. For a
  course whose point is C or C++, "it worked in the browser" diverging from "it
  compiles with the course toolchain" is a pedagogical risk, not just an
  engineering one — and worth settling before the work, because no amount of
  substrate makes it go away.

`xeus-sqlite` is the opposite trade from Lua: tiny, but SQL has no modules, no
functions and no student-module-under-test, so most of the grading contract does
not apply. A good assumption-finder, a misleading architecture test.

## The browser half, step by step

Each step names the file, and the check that proves it.

### 1. Declare the environment

`Tools/jupyterlite/environment-<lang>.yml`, modelled on the existing two. Keep it
minimal: **a kernel env has two costs and they fall on different people.** Boot is
paid by everyone on every notebook open and every browser-graded submission;
import/attach is paid only by a script that uses the package but is charged
against the 10-second per-test limit. See
[docs/kernel-boot-cost.md](kernel-boot-cost.md) before adding anything beyond the
kernel itself.

**Name the environment `chickadee-<lang>`.** Not cosmetic:
`build-jupyterlite.sh` derives the module index by globbing
`Public/jupyterlite/xeus/chickadee-*`, so an env named anything else is skipped
silently and ships with no index at all — on-demand loading then resolves nothing
and the authoring import guard has no package list to check against.

### 2. Vendor it

Run `.github/workflows/revendor-kernels.yml` (workflow_dispatch). It installs
micromamba, builds, and commits the result. **Do not hand-edit anything under
`Public/jupyterlite/`** — it is generated output.

Locally, if you have micromamba and network to `repo.prefix.dev`:

```bash
scripts/setup-jupyterlite.sh
scripts/build-jupyterlite.sh
```

`build-jupyterlite.sh` needs `rsync` on PATH and will tell you if it is missing.

### 3. Give it a module index

`scripts/derive-kernel-modules.py` currently branches Python/R by looking for
`r-base` in the env. Add a scan mode: find where the language installs packages
inside the tarballs, and emit `modules` plus `moduleOwners` (module name → conda
package). That map is what turns a runtime "no such module" back into something
installable.

It reads the **vendored tarballs, never the env YAML** — deliberately. Adding a
name to the YAML changes nothing until the kernel is rebuilt, so a check derived
from the YAML would accept imports the shipped kernel cannot serve.

If the language has no package ecosystem, emit an empty `moduleOwners`. On-demand
loading then correctly does nothing.

### 4. Register it with the vendoring guard

`scripts/check-xeus-vendored.sh` carries
`expected_language = {"xpython": "python", "xr": "r"}` and iterates **that map**,
not `kernels.json`. A third kernel that is not in it ships completely unguarded:
a partial or botched re-vendor of your kernel passes CI. Add the entry when you
add the env.

### 5. Write the language module

`Public/<lang>-grading-shared.js`, exporting:

- the kernel spec — `envName`, `kernelName`, `sharedLibs`, `argv`,
  `needsPythonRuntime`, and `bootSeeds` (the packages to boot; omit for the whole
  env, which is what you want until subsetting is proven)
- how to build the cell that runs one script and reports its exit code
- how to parse the reply back into `{ exitCode, stdout, stderr }`

Mirror the kernel's own `kernel.json` for `sharedLibs` and `argv`.
`python-grading-shared.test.mjs` asserts that correspondence for Python — write
the equivalent, because getting it wrong fails at boot with an opaque error.

### 6. Write the worker

`Public/<lang>-grading-worker.js` — about 150 lines, mostly protocol. Copy
`r-grading-worker.js`; it is the shorter of the two. You supply:

- `boot(spec, { seeds })`
- the missing-package regex, and where in the reply to look for it
- an optional post-install step (Python needs `importlib.invalidate_caches()`;
  R needs nothing)

The retry loop itself is `runInstallingMissingPackages` in the shared substrate.
Do not reimplement it.

### 7. Route to it

- `Public/browser-runner.js` — `RoutingExecutor` picks a worker by script
  extension.
- `Sources/RunnerCore/ScriptClassification.swift` — `classifyScriptInterpreter`
  maps the same extension to a native subprocess command, so the worker and the
  browser agree.

### 8. Allowlist the worker for cross-origin isolation

`NotebookAssetIsolationMiddleware.isolatedWorkerScripts`. **This one has bitten
us.** The notebook page is cross-origin isolated on Chromium and Firefox, and a
worker created by a `require-corp` document must itself be served `require-corp`
or the browser refuses the script. When that happens the failure is silent: the
submission fails over to the native worker and grades correctly, just slowly, so
nothing looks broken. That is how #1274 shipped browser-graded R that no isolated
engine ever ran.

The allowlist is per-path, so "same directory as an allowed worker" proves
nothing. `IsolatedWorkerScriptDriftTests` reads the spawn sites out of the page
scripts and fails on drift in either direction.

### 9. Ship a runtime helper

`Tools/runner-support/test_runtime.<x>` — the `passed()` / `failed()` / `errored()`
API a test script calls. It must behave identically under the native subprocess
and in the kernel, which have no process contract in common. See
[docs/r-support.md](r-support.md) for what that cost in R: `quit()` and
`commandArgs()` had to be masked in the global environment so one file works in
both.

### 10. Prove it on a real kernel

Add a fixture to `Tools/browser-grading-smoke/smoke.mjs` and run:

```bash
node Tools/browser-grading-smoke/smoke.mjs --language <lang> --browser chromium
```

**Nothing else proves any of this.** The Node suite in
`Tests/BrowserRunnerJSTests` runs against a fake worker; `swift test` never
leaves the server. Only this boots a kernel. Cover, at minimum: a pass, a fail,
an uncaught error with its message on stderr, and — if the language has packages
— one that installs on demand and one naming a package the env does not have.

## Traps, each of which cost us a day

- **A guard that compares the vendored tree to itself proves nothing about
  intent.** `check-env-vendored-sync.sh` is the one that compares declared YAML
  to shipped bytes. Keep your env in it.
- **Installs must run from the environment prefix.** By the time a script
  triggers an on-demand install, the kernel has `chdir`'d into the student
  workspace, and the unpacker resolves relative to cwd. `addPackages` handles
  this; if you write your own install path, do the same.
- **Check what the test asks for before bisecting the product.** The editor
  smoke defaulted to `?kernel=python` — the *Pyodide* kernelspec — long after
  Pyodide stopped being the default. Deleting Pyodide made every leg request a
  kernel that no longer existed, WebKit failed deterministically and Chromium
  did not, and it read exactly like an engine regression. Three innocent changes
  were reverted before anyone read the fixture.
- **Per-extension guards go stale silently.** The `Atomics.waitAsync` patch
  globbed only the Pyodide extension for two releases while the xeus extension
  shipped the same unpatched polyfill. Glob every extension.
- **Two places enumerate the kernels rather than discovering them**, and both
  fail open for a kernel they have never heard of: the `chickadee-*` glob in
  `build-jupyterlite.sh` (no module index) and `expected_language` in
  `check-xeus-vendored.sh` (no vendoring guard). Neither errors; you simply get
  a kernel nothing checks. Grep for your env and kernel name after vendoring and
  confirm both mention it.
- **Do not add a `default:` arm to a language switch.** The compiler producing
  the worklist is the entire reason the count of touched files is acceptable.
  See `docs/language-handling-review.md` §4.

## Where the second half begins

Once scripts run, you have a language that can be *graded* and not one that can
be *authored*. Still needed, and each is a new artifact:

- a `JSONValue.<x>Literal` renderer, and inputs-file rendering on
  `AssignmentLanguage`
- `PatternFamilyRenderer<X>` — the eight generated kinds
- `NotebookCheckRenderer<X>` plus its kind-support gate
- a personalization driver and seed runtime — including the language's answer to
  R's no-bignum problem (`RPersonalizationRuntime.chickadeeSeedRSource`)
- a submission-normalization strategy. `shouldNormalizePythonSubmission` is
  shaped "R, or else Python" and is the one language decision the compiler will
  not force you to make; there is a comment at the function saying so.
- notebook kernel-name aliases (`AssignmentLanguage.rKernelNames` generalises to
  per-language sets), runner capability strings, and the MCP tool descriptions
  that currently say "Python or R"
