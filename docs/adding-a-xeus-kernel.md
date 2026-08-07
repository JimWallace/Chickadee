# Adding a xeus kernel

How to teach Chickadee another in-browser language, and — more usefully — what
that actually costs.

> **This has now been done once, deliberately, with Lua.** Everything below was
> written before; §"What the Lua run actually cost" at the end records what
> held, what did not, and which of R's expensive lessons turned out not to
> generalise. Read the two together — where they disagree, the Lua section is
> the measurement and this text is the prediction.

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
first, then gives the second as a compiler-generated worklist and a done test.

**The two halves are not independently shippable.** Vendoring a kernel registers
its kernelspec in the editor, so stopping after the first half leaves an
authorable language with no extraction or rendering behind it. Chickadee has
exactly one rule here: a language is supported or it is not present. If you are
not going to finish the second half, do not vendor the kernel — spike it on a
throwaway branch instead.

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

*This is what was done.* See "What the Lua run actually cost" below.

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

  **Re-vendor the browser wasm in the same change.** `RoutingExecutor` calls
  `classifyScript` out of the vendored `Public/runner-wasm/`, so until that is
  rebuilt the browser classifies your extension as `unsupported` while the
  native worker handles it fine — the #801 failure class.
  `runner-wasm-vendor.yml` heals it on merge to `main`, but a release ships in
  between. Run `scripts/build-runner-wasm.sh`, then
  `scripts/runnercore-source-hash.sh > Public/runner-wasm/source.sha`.

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

## The second half: making the language *supported*

Once scripts run you have a language that can be **graded** and not one that can
be **authored**. That gap is not a rough edge — it is most of the work, and
Chickadee has now been on both sides of it. Lua reached the end of the first
half in a day; the second half is an R-sized arc.

> **Status: Lua has now finished the second half.** `AssignmentLanguage` is
> `.python | .r | .lua`. Everything below is the runbook that produced it, and
> the counts are what the compiler actually named. The section further down,
> "What a half-supported language actually does", describes the state Lua was in
> *before* this landed; it is kept because it is the measured argument for
> finishing, not a description of current behaviour.
>
> Two things the Lua run added to this runbook, both learned by getting them
> wrong first:
>
> * **Generalise a lesson to its neighbour.** The conformance matrix put the
>   eval flag in the per-language adapter after `-c`/`-e` bit it, and left the
>   availability probe hardcoded to `--version` three lines away. `lua` does not
>   accept `--version`, so every executed assertion for Lua skipped silently and
>   the suite reported green. When you fix a per-language hardcode, look at what
>   sits beside it.
> * **Run the generated code, not just the parser.** Parse checks passed on a
>   `_ck_inputs.lua` that opened with `#` — a Python comment — because Lua skips
>   a first line starting with `#` as a shebang. It would have broken the moment
>   anything moved above it, and the failure mode is every per-student value
>   reading as missing rather than anything erroring.

**There is no such thing as a grading-only kernel.** A vendored kernel is
registered in `Public/jupyterlite/xeus/kernels.json`, which means the xeus
extension registers its kernelspec at editor startup and it becomes reachable
in Kernel -> Change Kernel. An author can then produce a notebook in a language
whose extraction path does not exist, and find out at submission time. If you
are not going to finish the second half, do not vendor the kernel.

### The worklist is compiler-generated — use that

Do NOT write this list by hand. Add the case and let the type checker enumerate
the work:

```bash
swift build 2>&1 | grep "error:" | sort -u
```

Every `switch` over `AssignmentLanguage` is deliberately exhaustive with no
`default:` arm, for exactly this reason (see
[docs/language-handling-review.md](language-handling-review.md) §4). Adding
`case lua` to `Sources/Core/AssignmentLanguage.swift` and rebuilding produced,
in three passes, the complete census below. Each pass fixes one layer and
reveals the next, because a target only type-checks once its dependency does:

| Pass | Layer | Sites |
|---|---|---|
| 1 | `Core` | 11 |
| 2 | `RunnerCore` + `Worker` | 3 |
| 3 | `APIServer` | 12 |

That is **26** compiler-named sites, measured on the Lua run rather than
estimated. Two notes on why your split may differ:

* `Core` is 11 rather than the 10 this table first said, because
  `notebookKernelNames` — the per-language generalisation of `rKernelNames` —
  landed after the first count.
* `RunnerCore` contributed **zero**, and that is not a saving. Lua's
  `extractLua` had already landed with the browser-grading work, so the pass-2
  sites were all in `Worker`. A language whose extraction is not pre-landed
  pays for it here instead.

**The compiler cannot see seven more**, listed under "What the compiler will not
tell you" below — those are the ones that have historically shipped broken.

### The 26 the compiler names

**`Sources/Core/AssignmentLanguage.swift`** — the hub. The FACTS now live in one
`LanguageDescriptor` literal per language (`Core/LanguageDescriptor.swift`), so
most of this is one struct to write rather than eleven arms to find: display
name, script extensions, generated extension, inputs filename, kernel aliases,
kernel env file, missing-dependency wording, interpreter probe.

That file also records why this is a descriptor on a closed enum rather than a
protocol or a class hierarchy — short version: a closed enum makes a missing
answer a **compile error**, and the alternatives make an omission look like a
decision. Read it before proposing to change the shape.

One judgement remains, and it replaced three:

- `moduleResolution` — **how does the language reach code that is not the
  student's?** `.fileRead` (R's `source()`) or `.byName(searchPathVariable:)`
  (Python, Lua). From it `runnerProvidedModules`, `studentModulePrefixes` and
  `supportFilesPathEnvironmentVariable` are all *derived*, so a new language
  answers one question instead of three — and cannot answer them
  inconsistently, which was possible before and had happened.

  R is `.fileRead` and Lua is `.byName` for the same runtime helper, which is
  the whole reason this must be answered from the language rather than copied
  from the neighbour.
- `workingDirectoryIsOnDefaultSearchPath` — the one FACT the mechanism cannot
  supply. Lua puts `./?.lua` on `package.path` and so needs no variable set;
  Python resolves by name just the same and does. Verify it, do not assume:
  `lua -e 'print(package.path)'`.

**Facts that used to be sites are now fields.** Three things that were
hand-written arms per language are read off the descriptor, so writing the
literal is the whole job:

| field | what stopped being a site |
|---|---|
| `jupyterLiteKernelName` / `…DisplayName` | `normalizeNotebookForJupyterLite` iterates `allCases` instead of one `else if` per language — the arm that shipped without a Lua twin |
| `scriptExtensions` | `contentType(for:)` and the browser's student-module hint both derive from it; the hint is *generated* into the JS (below) |
| `notebookKernelNames` | resolution, the normalizer, and the browser's kernel sets all read it |

The rule this encodes: **if a fact differs per language, put it on the
descriptor and loop — do not write an arm.** An arm is invisible to the
compiler when the next language arrives; a loop is not.

And two behaviours that take arguments and so stay methods: `literal(_:)` (needs
a new `JSONValue.<x>Literal`) and `renderInputsFile(_:)` (the `_ck_inputs.<x>`
contract, which must match byte-for-byte what the language's `test_runtime`
reads AND what the browser's `personalizationInputsSource<X>` writes).

**`Sources/RunnerCore/`** — notebook extraction. If the language flattens cells
behind an inert comment marker (as R and Lua both do), reuse
`extractWithCellMarkers` rather than adding a third copy; Python is genuinely
different and keeps its own. The marker must round-trip through the language's
`chickadee_student_cells()`.

**`Sources/Worker/`** — `NotebookExtractor` (output extension + assembly) and
`SubmissionStaging` (the `.ipynb` -> source name).

**`Sources/APIServer/`** — 12 sites, dominated by two:

- `PatternFamilyRenderer.swift` (x2) — a `renderLuaPatternCase` and an
  existence guard covering **8 kinds**
- `NotebookCheckRenderer.swift` — a `renderLuaNotebookCheck` covering **9**
  (`astStructure` is Python-only by design)
- `PersonalizationEvaluator.swift` (x2) — the driver script and its value
  emission, plus a seed runtime answering the language's version of R's
  no-bignum problem (`RPersonalizationRuntime.chickadeeSeedRSource`)
- `KernelEnvironment` (x2), `KernelImportGuard`, `NotebookCheckKindHandler`
  (x2), `NotebookCheckValidator`, `TestScriptVariablePrepender` — small arms

**Budget the renderers honestly.** `PatternFamilyRendererR.swift` is 545 lines
and `NotebookCheckRendererR*.swift` is 650. Lua came in at 604 + 300, plus 59
for identifier/comment helpers and 108 for the personalization runtime — about
1,070 lines, so R's figure is a fair estimate and not a worst case. They are the
bulk of the second half, and they are *code that generates student-facing test
code* — a subtle error is a wrong mark, not a crash. Do not write them without
running the generated source against a real interpreter, which is the same rule
the rest of this document keeps arriving at.

**A note on how much of that is shareable, since it is tempting to assume most
of it.** It is less than it looks. The three renderers agree on the *sequence*
(load, call, compare, report) and on the field labels — the labels are now
shared, in `GeneratedMessage`, which is where a new language should get them.
They do NOT agree on prose: `performanceThreshold` says `threshold:`/`elapsed:`
in Python and `budget:`/`took:` in R, and `exceptionExpected` uses different
sentences in each. Python's bytes are additionally frozen by `spec_hash`, so
unifying the kinds into one implementation would rewrite every existing
assignment's manifest — a product decision, not a refactor. Structure the new
renderer like `PatternFamilyRendererR.swift` (one switch, one small body per
kind), take the vocabulary from `GeneratedMessage`, and do not try to collapse
the three.

### What the compiler will *not* tell you

**Seven** things, each of which has shipped broken at least once. Numbers 5-7
were found during the Lua run; 5 is the most dangerous, because it is a shape
rather than a place, and 6-7 are whole subsystems that needed no change to their
types and so pointed at nothing.

1. **The interpreter on the runner image.** `Dockerfile` installs `python3`,
   `r-base` and `lua5.4`. A language whose binary is missing fails `env <lang>`
   with command-not-found — and because instructor validation is enqueued as a
   `kind == .validation` submission graded by the **native worker**, even a
   purely browser-graded assignment cannot be validated. This shipped with Lua.
   `theRunnerImageProvidesEveryInterpreter` in the conformance matrix now
   asserts it per language.
2. **`shouldNormalizePythonSubmission`** is shaped "R, or else Python". It is
   the one language decision the compiler will not force; there is a comment at
   the function saying so. **Still true after Lua** — Lua reaches the generic
   notebook extractor through the same predicate R does, so it behaves, but the
   shape is unchanged and the next language should expect to fix it properly
   rather than ride it.
3. **The generated JS constants.** `scripts/generate-js-constants.sh` now
   **discovers** every `<lang>KernelNames` declaration and writes a fenced
   `<LANG>_KERNEL_NAMES` block per language, failing when one has no block to
   write into. It used to hardcode `rKernelNames`, which meant a new language
   generated nothing and the browser kept routing its notebooks to Python. So
   this item is now *loud* rather than silent — but you still have to add the
   fenced block, and the script tells you so.

   It also generates `GRADED_SCRIPT_EXTENSIONS` from the union of
   `scriptExtensions` across the descriptors, which is what decides whether a
   directly-uploaded file gets a `.chickadee_student_module` hint. That list was
   hand-written as `.py` / `.r`, so a `.lua` upload got no hint and
   `test_runtime.lua` — hint-only, because Lua cannot list a directory — could
   not find it. A new language's extension now reaches the browser the day its
   descriptor literal lands.
4. **The vendored browser wasm.** `RoutingExecutor` calls `classifyScript` out
   of `Public/runner-wasm/`, so the browser disagrees with the worker until it
   is rebuilt — and a new RunnerCore export (`extractLua`) simply does not exist
   there until then. Rebuild in the same change:

   ```bash
   scripts/build-runner-wasm.sh
   scripts/runnercore-source-hash.sh > Public/runner-wasm/source.sha
   ```

   It IS buildable on a normal machine, contrary to how this once read: swiftly
   installs Swift 6.3.2 and `swift sdk install` takes the bundle pinned in
   `wasm/wasm-sdk.pin`, both over ordinary network. Budget ~20 minutes.

   Beware the window: `runner-wasm-vendor.yml` only re-vendors on **main**, so a
   loader that *requires* a new export fails browser grading over to the native
   worker for EVERY language until that job runs. Check new exports at their use
   site, not in the readiness gate.
5. **Boolean sniffs that type-check fine.** The compiler forces exhaustive
   `switch`es. It does not force `isRNotebook(nb) ? .r : .python`, a ternary
   that compiles perfectly however many languages exist and routes the new one
   down the Python branch. `NotebookExtractor` had exactly this, so a Lua
   notebook was extracted as Python.

   Find them by searching for the *default* rather than for the language:

   ```bash
   grep -rn "? \.r : \.python\|== \.python ?\|isRNotebook\|hasRScript" Sources/
   ```

   The fix is always the same: resolve positively with
   `AssignmentLanguage.fromNotebookMetadata` (or the shared
   `gradedScriptLanguage(in:)` for the suite half), which returns the language
   it recognised or nil for "nothing recognisable, use the default" — the
   distinction the ternary cannot express.

   **This bit twice, and the second instance shipped in #1282 and was caught
   only by the follow-up audit.** `AssignmentLanguage.resolve` detected `.R`
   scripts and `rKernelNames` by hand, and `rederive` ended in the literal
   `isRNotebookMetadata(metadata) ? .r : .python` above — so every real Lua
   assignment resolved to Python at all 18 `resolve(for:)` sites (families and
   checks rendered as `.py`, the worker wrote `_ck_inputs.py`), while every Lua
   *test* passed because it injected `.lua` explicitly. The lesson is not "add
   another entry to this list" — it is that the grep above must actually be
   **run**, over the hub file included, because the hub is exactly where a
   sniff hides in plain sight. Both are now `gradedScriptLanguage(in:)` +
   `fromNotebookMetadata`, and `AssignmentLanguageTests` has an
   `allCases`-driven row per language that fails if any one falls through.

   The same shape appears wherever a language is *stored* rather than switched
   on. `KernelEnvironments` had one property per language plus a subscript, and
   only the subscript was a compile error; the loader and the struct could be
   missed, leaving the new language with a permanently nil inventory. It is
   keyed by language now.
6. **Runner capability matching, in BOTH directions.** `RunnerProfileDetector`
   hand-listed the interpreters it probes, so no runner advertised the new
   language however it was provisioned — and that is worse than an omission,
   because an assignment REQUIRING the language then matched no runner and
   queued forever. `detectRequirementSuggestions` hand-listed extensions, so an
   assignment in the new language suggested no requirement and its jobs went to
   any runner, including one with no interpreter (every test exiting 127). Both
   read `AssignmentLanguage` now — the probe from `allCases`, extensions from
   the one extension table.

   The probe's ARGUMENTS matter as much as its command: `--version` works for
   python3 and R and **fails on lua**, which exits 1 with a usage message. A
   hardcoded `--version` leaves the language undetectable even after it is added
   to the loop.
7. **The submission policy.** See "The submission policy" below. Nothing fails when a
   language is missing from it; the student just gets silence instead of a
   message.

### What this model cannot see, scored against three languages it does not have

The reduction above — three judgements to one plus one fact — was checked
against Octave, Java and C++ *before* it was made, because a theory that is
clean on three data points is exactly when it is most likely overfitted. It
survived, but not intact, and the failures are the useful part.

| language | `moduleResolution` | derives? |
|---|---|---|
| Python | `byName("PYTHONPATH")`, `sitecustomize` hook | yes |
| R | `fileRead` (`source()`) | yes |
| Lua | `byName("LUA_PATH")`, cwd already on path | yes |
| Octave | `byName("OCTAVE_PATH")`, resolved by filename | yes — with the extra fact |
| Java | `byName("CLASSPATH")` | yes |
| C++ | none; `#include` is compile-time | no — see below |

**Octave is why one judgement was not enough.** R is file-based and needs no
path variable. Octave is file-based in spirit and *does* need `OCTAVE_PATH`.
What decides it is not the mechanism but whether the default search path already
contains the working directory — a per-implementation accident. Without the
fourth language that would have shipped as a clean-looking derivation that was
quietly wrong for the next language to arrive.

**Two axes the model cannot represent at all.** All three current languages sit
on the same side of both, so neither is visible in the code:

1. **Interpreted vs compiled.** Every `ScriptInterpreter` case hands a *file* to
   a *command*. Java and C++ need a build step first. Chickadee HAS one
   (`TestProperties.makefile`), so this is not a wall — but nothing in
   `AssignmentLanguage` knows about it, and `interpreterProbe` in particular
   assumes a thing you can hand a file to.
2. **Dynamically vs statically typed literals.** `literal(_:)` renders a
   `JSONValue`, which is dynamically typed. C++ needs a type for every literal,
   so `[1, "two"]` has no rendering at all. That is an impossibility, not a
   judgement, and it would force this type to grow a notion of *which
   `JSONValue` shapes can I render* — which none of the three current languages
   need.

**The reframe worth carrying forward:** a language does not have to be an
`AssignmentLanguage` to be graded. Chickadee can grade C++ today through a `.sh`
suite script and the `make` step, with none of this machinery. `AssignmentLanguage`
is about AUTHORING — generated pattern families, notebook checks,
personalization, in-browser kernels. So the first question about a candidate
language is not "what is its module system" but **"does it want the authoring
surface at all?"** For a compiled language the honest answer may be no, and that
is a much cheaper place to land than half of this document.

### The submission policy: what a student is guaranteed

Separate from "does the language grade", and easy to skip because nothing fails
when you do. `Sources/Worker/SubmissionPolicy.swift` states, once, what
Chickadee promises a student about their upload — valid notebook JSON, at least
one code cell, unsupported files warn rather than fail, no gradeable source is
an error naming the language. Adding a language means answering
`submissionGuaranteeExemption` for every guarantee.

**It is a policy value, not a protocol, and that is deliberate.** A protocol
scatters the policy across N conformances where it cannot be read as policy,
and — worse — it makes opting out INVISIBLE: an empty method body or an
inherited default is indistinguishable from a decision nobody made. That is
precisely how R and Lua ended up with no submission validation at all while
Python had 445 lines of it. Here an exemption is a value with a reason attached,
the reason is greppable, and `SubmissionPolicyTests` fails on an empty one.

It is also not where the variation is. Walking the upload, MIME-classifying it,
checking a notebook parses and has code cells, warning on files that cannot be
graded — none of those are language questions. The genuinely per-language part
is which extractor runs and what the output is called, and that already lives in
RunnerCore.

**Most guarantees admit no exemption, on purpose.** There is no honest reason
for an R student to get silence where a Python student gets a message; that
difference was never decided, it was just unbuilt. `theUniversalGuaranteesHaveNoExemptions`
enforces it, and its failure message says so. The valve exists for things
genuinely shaped by the language — today exactly one: R and Lua skip the
introspectable `.source.*` sidecar, because it exists for `astStructure` checks
and those are Python-only by design, so nothing would ever read the file.

One scoping rule worth knowing before you touch it: the guarantees apply to the
**student's own notebook**, identified by filename, and not to every `.ipynb` in
the workspace. An instructor's bundled helper may legitimately be
markdown-only, and failing a job over one would be a regression dressed as a
fix. The Python normalizer gets that scoping free by walking only the
submission directory; the generic extractor walks the merged workspace, so it is
told which file is the student's.

### The browser half's own checklist

The four (five) above are Swift-side. The browser has its own set, none of
which the Swift compiler can see, and all of which the Lua run had to touch:

| What | Where | Fails as |
|---|---|---|
| the inputs writer | `personalizationInputsSource<X>` in `<lang>-grading-shared.js` | every per-student value missing, silently |
| the language branch that calls it | `browser-runner.js`, beside the `_ck_inputs.R` / `.py` arms | Python's file written for your language |
| notebook extraction routing | `browser-runner.js` `extractNotebookToMap` | a `.py` file made from your notebook |
| the page `<script>` tag | `Resources/Views/_notebook-body.leaf` | `ReferenceError` at runner load — for EVERY language |
| each JS test harness's vm context | `Tests/BrowserRunnerJSTests/*.mjs` that build a context | the same `ReferenceError`, in tests only |

That last pair is the enumeration trap again: `browser-runner.js` destructures
its shared modules at IIFE start, so every harness that runs it has to load the
same set the page does. Three files list that set independently.

### The done test

The language is supported when all of these are true. Anything less is the
state this document exists to warn you about:

- [ ] `swift build` is clean with the new case and **no `default:` arm added**
- [ ] the interpreter is on the runner image, and worker grading of a
      hand-authored test passes
- [ ] instructor validation of an assignment in the language passes
- [ ] `Tools/browser-grading-smoke --language <x>` passes on a real kernel
- [ ] a notebook in the language extracts, and its cells round-trip through
      `chickadee_student_cells()`
- [ ] a pattern family generates, and the generated source runs under the real
      interpreter
- [ ] a notebook check generates, ditto
- [ ] a per-student `=` expression evaluates, and the seed the driver binds
      equals the seed a graded script reads
- [ ] `_ck_inputs.<x>` is *written* by both the worker and the browser, not
      merely readable by the runtime
- [ ] the generated scripts are **executed**, not merely parsed — against a
      correct submission AND a wrong one, so both the pass and the failure
      message are seen
- [ ] `LanguageConformanceMatrixTests` is green with the new case **and the
      interpreter actually present**; confirm the executed half did not skip
- [ ] `LanguagePipelineWalkTests` is green — it starts from a manifest, RESOLVES
      the language, and walks the resolved answer through the renderers, the
      inputs file and the editor kernel. The matrix proves each stage works when
      handed your language; this proves the pipeline *agrees* on it. Every
      audit defect lived in that joint, not in a stage
- [ ] `submissionGuaranteeExemption` is answered for every guarantee, and every
      exemption carries a reason you would defend to an instructor
- [ ] a runner ADVERTISES the language (`interpreterProbe`) and an assignment in
      it SUGGESTS a requirement — capability matching fails in both directions
      and the second is worse: requiring a language no runner advertises queues
      the assignment's jobs forever

That fourth-from-last one is a real trap: Lua's runtime could read
`_ck_inputs.lua` from day one, and the smoke test supplied one as a fixture —
which proved the *reader* worked and said nothing about whether anything ever
wrote it.

The last two are the Lua run's own contribution, and both caught real defects a
parse-only check could not:

* The matrix's interpreter probe hardcoded `--version`, which `lua` rejects, so
  every executed Lua assertion skipped **silently** and the suite reported green
  having never run any generated Lua. The probe arguments are a per-language
  adapter field now — but the general lesson is to prove a skip-when-absent test
  did not skip, by breaking it once and watching it fail.
* `_ck_inputs.lua` opened with `#`, a Python comment. It *parsed*, because Lua
  skips a first line starting with `#` as a shebang. Executing it was the only
  thing that could have distinguished "correct" from "accidentally survivable".

## What a half-supported language actually does

Lua spent one release in the state this document now forbids — kernel vendored,
first half done, second half not — so what that state *does* is measured rather
than predicted. Read this before deciding to ship half.

**This section is history, not current behaviour.** Lua has since finished the
second half; it is kept because it is the evidence for the rule at the top of
this document, and the next language will be tempted by the same shortcut.

The short version: **the failure is loud where it matters and silent where it
does not**, and the loud part is load-bearing. Do not "fix" it without replacing
it.

### The path an instructor actually takes

| Step | What happens | Verified |
|---|---|---|
| Author `publictest_x.lua` | MCP `author_script` accepts it — no extension allowlist | code |
| …via the web *upload* | **rejected** — `isLikelyTestSuiteFile` lists `sh/bash/zsh/py/r/rb/pl/js/php`, not `lua` | code |
| Language resolution | `AssignmentLanguage(scriptExtension: "lua")` is nil → resolves to `.python` | code |
| Grading mode | defaults to **`worker`** (`APICourseSection.defaultGradingMode`) | code |
| Worker runs it | `/usr/bin/env lua …` → **exit 127**, `env: 'lua': No such file or directory` | run |
| RunnerCore maps 127 | not 0/1/3 → **`.error`** | code |

Two things are worth noticing.

**It errors, it does not fail.** Exit 127 lands in the `default:` arm, so every
test reports `error` with the `env:` message in `longResult`. That is the
difference between "this assignment is broken" and "this student is wrong", and
it is the only reason a half-supported language is survivable at all.

**Validation catches it before students do.** Instructor validation is enqueued
as a `kind == .validation` submission graded by the **native worker**, so the
instructor hits exit 127 on their own reference solution — in browser-graded
mode too, where student grading would otherwise have worked. The instructor
cannot reach a class without first seeing it fail. That is an accident of the
architecture, not a designed guard, and validation is advisory rather than
blocking — but it is what has been standing between a half-supported language
and a broken lab.

### The trap: fixing the interpreter makes it quieter, not safer

Putting the interpreter on the runner image removes exit 127. That fixes the
*script* path — and removes the loud signal that was masking a set of silent
ones, because the assignment still resolves to `.python`:

- `_ck_inputs.py` is written; the Lua runtime reads `_ck_inputs.lua` and gets an
  **empty table**. Every per-student input silently becomes nil. No error.
- pattern families generate `.py` cases (`generatedScriptExtension` follows the
  resolved language), which then run under `python3` inside a Lua assignment.
- notebook checks, the same.
- a notebook whose kernel is `xlua` extracts through the **Python** sanitizer,
  because `isRNotebook` is false and `.python` is the fallback — producing an
  `analysis.py` of mangled Lua.

So the honest ordering is: **the interpreter fix is only safe as part of
finishing the second half.** On its own it trades one visible error for four
invisible wrong answers. If you land it early — as we did, because worker
grading and validation were outright broken without it — say so, and keep the
language out of instructors' hands by another means until the rest lands.

### The closure options, and the rule

There are only two honest end states, and "kernel vendored, renderers missing"
is neither:

1. **Finish the second half.** The worklist above is exact.
2. **Remove the language.** Delete the env, the worker, the routing and the
   `kernels.json` entry.

If you need a holding position between them, the chokepoint is the four
hand-authored script write sites (`KernelImportGuard` is already wired into
exactly those: the web create/update handlers, `PUT /suite`, and MCP
`author_script`). A guard there that refuses to save a graded script in a
language that is not fully supported converts every silent failure above into
one clear refusal at authoring time. That is a deliberate decision to take, not
a default to drift into.

## What the Lua run actually cost

Lua shipped as `chickadee-lua` / `xlua`, browser-graded through
`Public/lua-grading-worker.js`, and it stopped exactly where this document said
it would: a language that can be **graded** and not one that can be **authored**.
`AssignmentLanguage` is still `.python | .r`, there is no Lua literal renderer,
no pattern-family or notebook-check renderer, and no personalization driver. So
the boundary in "Where the second half begins" is real and was not crossed.

### What held

The claim that **the browser substrate is language-agnostic** survived contact.
`Public/xeus-kernel-shared.js` was not modified — not one line. The whole
browser half is two new files (a ~230-line `lua-grading-shared.js` and a
~130-line worker that is mostly protocol), plus one arm each in
`interpreterToKind`, `RoutingExecutor`, `ScriptClassification.swift` and
`ScriptInvocation.swift`.

The enumerated-not-discovered traps were also real, and both were hit exactly
where predicted: `expected_language` in `check-xeus-vendored.sh` and the
`XEUS_ENVS` array in `build-jupyterlite.sh`. Neither errors on a kernel it has
never heard of. The `chickadee-*` naming rule is what made the module-index step
pick the new env up for free.

### What did not hold — R's two expensive lessons do not generalise

This is the finding worth carrying forward. Both of R's hard-won rules are
**xeus-r properties, not xeus-lite ones**, and treating them as substrate law
would have cost days for nothing:

- **The one-top-level-expression rule.** xeus-r yields to the JS event loop
  between top-level expressions and does not regain control for ~180ms. Measured
  on xeus-lua: a cell of 20 top-level `print` statements costs **5ms**, and a
  cell summing 20 million integers costs **184ms** — wall time tracks the work,
  which is precisely what the R numbers showed was *not* happening there. (This
  matches the xeus-python spike, which measured a 5ms per-cell floor.)
- **Reading stderr off the kernel's stream because a sink cannot see it.** That
  is `evaluate::evaluate()`'s calling handlers, which are an R thing. Lua's
  `io.stderr:write` reaches the kernel's stderr stream directly, and the wrapper
  writes an uncaught error there itself.

The lesson is not "ignore the R notes" but "each kernel's quirk is its own".
Budget for one per kernel, as this document says; do not budget for the *same*
one.

### The quirk Lua did have, which no manifest predicts

xeus-lua compiles a cell as `return <cell>` first, so it can report a value, and
falls back to running it as a plain block. A cell that opens with a `local`
declaration and then uses it satisfies neither reading cleanly — the fallback
reports the name as an undefined **global**, with a confusing error naming a
`_xeus_lua_return_expression` chunk the author never wrote. The wrapper is
therefore a single call expression into a harness installed once at boot, which
sidesteps the question: the harness's own statements are inside a function the
kernel never re-parses.

So Lua and R both end up sending "one expression" per script, for entirely
unrelated reasons. That coincidence is a good way to reach the wrong conclusion
about the next kernel.

### The other per-language work, which was not substrate work

- **`os.exit` masking**, the direct analogue of R's `quit()` masking — and the
  same failure mode if it regresses: `passed()` and `failed()` would both raise
  nothing the wrapper recognises, and every test would read as a clean exit 0.
  The smoke test is the only thing that can see this.
- **A per-script wipe of globals added since boot**, standing in for the fresh
  process the native runner gives each test. R clears its global environment
  outright; Lua cannot — `_G` *is* the standard library — so the wipe is keyed
  on a boot snapshot. Two smoke fixtures (one leaks a global, the next asserts
  it is gone and that `print` still exists) are what prove it.
- **`package.path`.** `lua script.lua` searches the working directory; the
  kernel's path points only at its own asset dir, so `require("test_runtime")`
  would have failed in the browser and nowhere else.
- **No directory listing.** `test_runtime.lua` cannot scan for the submission
  the way its R and Python siblings do — Lua's standard library has no
  `list.files`, and `io.popen` is a subprocess the wasm kernel does not have. It
  reads the runner's `.chickadee_student_module` hint, which is written on every
  job, with `solution.lua` as the fallback.

### Costs, measured

| | Lua | R | Python |
|---|---|---|---|
| env on disk | **19 MB** | 74 MB | 85 MB |
| kernel boot (Chromium, local disk) | **2.5–3.1s** | ~4.0s | ~5.2s |
| slowest graded script | **27ms** | seconds (attach) | ~1.1s |
| packages available | **none** | 51 | 48 |

"None" is the correct answer and not a gap: emscripten-forge carries no Lua
library packages, so `importable-modules.json` has an empty `moduleOwners` and
`runInstallingMissingPackages` correctly makes one pass and lets the original
`module 'x' not found` stand. That is the half of the on-demand mechanism a
student's typo actually hits, and Lua is the only env that can prove it
terminates with nothing to install.

`bootSeeds` is therefore also absent, deliberately: every package in the env is
in `xeus-lua`'s own transitive closure (the 6 MB `python` package arrives via
`jupyterlab_widgets` → `xwidgets` and is never executed), so a seed list would
select all ten and save nothing.

### One thing this document under-weighted

Adding a case to `ScriptInterpreter` changes `Sources/RunnerCore/`, which means
the **vendored browser wasm is stale until it is re-vendored** — the #801 class.
`runner-wasm-vendor.yml` handles it automatically on merge to `main`, but with a
one-release lag, during which `RoutingExecutor` would classify every `.lua`
script as `unsupported` while the worker beside it graded them perfectly. Build
it in the same change (`scripts/build-runner-wasm.sh`, then refresh
`Public/runner-wasm/source.sha`) rather than relying on the lag. Step 7 above
should say so.
