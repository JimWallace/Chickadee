# Adding a xeus kernel: the per-language postmortems

> Archived from `docs/adding-a-xeus-kernel.md` in #2723. The runbook is
> [adding-a-xeus-kernel.md](../adding-a-xeus-kernel.md). These sections record
> what the Lua, Octave and Java runs cost. They are history, not current
> behaviour. Their carry-forward rules are in the runbook.

## What the Lua run actually cost

Lua shipped as `chickadee-lua` / `xlua`, browser-graded through
`Public/lua-grading-worker.js`, and it stopped exactly where this document said
it would: a language that can be **graded** and not one that can be **authored**.
`AssignmentLanguage` is still `.python | .r`, there is no Lua literal renderer,
no pattern-family or notebook-check renderer, and no personalization driver. So
the boundary in "Where the second half begins" is real and was not crossed.

**Status since this run.** Lua later became a full `AssignmentLanguage`
(`.lua`). It has a literal renderer, a pattern-family renderer for every kind, a
notebook-check renderer for four of the ten kinds, and a personalization driver.
The six other check kinds are refused at save time, not left out. The four
data-frame kinds and `figureCount` need packages that Lua does not have.
`astStructure` is Python-only. `cellContains` also refuses `regex: true`.
`docs/authoring-parity.md` gives the reason for each refusal. The native worker
injects `Tools/runner-support/test_runtime.lua` beside the Python and R helpers,
so one file serves `lua script.lua` and the kernel.

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

(Point-in-time, as postmortems here are: `expected_language` was a literal map
when Lua was added. It has since been derived from the language descriptors, so
that half of the trap no longer applies to a seventh language — see the traps
section above, including what deriving it did *not* fix.)

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

## What the Octave run actually cost

The fourth language, done a second time by this runbook — and the first run
whose worklist was mostly *reading the answers off tables the audit
generalised*. Recorded here the way the Lua section is: what held, what the
measurements corrected, and the quirks no manifest predicted.

**What shipped.** Octave (`.octave`) grades `.m` scripts natively with
`octave-cli` and in the browser with the vendored `xeus-octave` kernel
(`chickadee-octave`). All pattern kinds render and execute. Five of the ten
notebook-check kinds are supported: `variableExists`, `functionExists`,
`numericArrayClose`, `cellContains` and `figureCount`. The four data-frame
kinds and `astStructure` are refused at save time.

### The headline: the invisible surface SHRANK

Lua's run found seven compiler-invisible items and turned four of them into
`allCases`-driven tables. Octave was the first test of whether that work
generalised, and it did: capability probing, requirement suggestions, the
web-upload extension allowlist, submission-ownership routing, the
student-module hint, and the generated JS constants all picked Octave up the
day its descriptor literal landed — zero edits, verified rather than assumed
(the conformance rows were broken once on purpose and watched to fail). What
was left by hand: the two Docker images, the runtime embed + per-workspace
injection, and the browser half's checklist. The compiler named 19 sites
(2 Core, 5 Worker, 12 APIServer) against Lua's 26, the difference being
exactly the arms that became descriptor fields.

### The scorecard was wrong about Octave, in the useful direction

`LanguageDescriptor`'s survey table predicted Octave needs `OCTAVE_PATH` set
because its cwd is off the default search path. Measured
(`octave-cli --eval "path"`, and the wasm kernel agrees): `.` is the FIRST
entry, so `workingDirectoryIsOnDefaultSearchPath` is true and no variable is
set. The two-part shape (one judgement + one measured fact) survives on
Python's evidence; the Octave row was an armchair answer and the table now
records the correction. Verify the fact, never inherit it — that instruction
existed before this run and this run is why it stays.

### Both of Lua's opposite answers flipped back, each verified before claiming

- `figureCount` is SUPPORTED. Plotting is core Octave, but neither runner
  gave it away free: the wasm kernel creates figures through its built-in
  plotly toolkit (probed: `figure(); plot(1:3)` headless, figures counted),
  while native `octave-cli` on a bare image errors
  "no graphics toolkits are available!" — the fix is `gnuplot-nox` +
  `fonts-freefont-otf` (~7 MB), without which every figureCount validation
  errors. Both images carry them now.
- `cellContains` keeps `regex: true`. Octave's `regexp` is PCRE (`\d`,
  alternation, `{n,m}` probed against octave-cli), so a Python-authored
  pattern transfers — the exact property whose absence made Lua refuse.

### The trap that earned its billing

`[65, "bc"]` is the char array `"Abc"` — no error, one stderr warning nobody
reads. The literal rule (`JSONValue.octaveLiteral`): `[...]` only for arrays
of numeric/boolean scalars (JSON null admitted as `NA`, which occupies its
slot); ANY string element, mixed kinds, nesting, objects and the empty array
render as cells. Strings never enter `[...]` because `["ab", "cd"]` is
`"abcd"` — the same trap in a different mask. Objects are `containers.Map`
constructor calls (isequal compares Maps by content, insertion-order
independent — measured), never `struct(...)`, whose cell-expansion rule turns
`struct("a", {1, 2})` into a 1×2 struct ARRAY. The execution test grades a
submission returning the cell (passes) against one returning the coerced char
array (fails) so the rule stays honest.

Equality sits on **isequaln**, not isequal: `NA`/NaN match themselves (an
authored `[60, null, 20]` case must), and Octave is already type-blind across
logical/int/double (`isequal(1, true)` is true — measured). Two Chickadee
rules ride on top: both-empty is equal whatever the container class (`[]` vs
`{}` vs `""` — the renderer spells an empty JSON array `{}` while students
compute `[]`), and numeric comparison is shape-blind (`a(:)` vs `b(:)` — the
renderer emits rows, students' arithmetic produces columns, and R's recycling
`==` already agreed). `unordered_equal` IS `equal` applied pairwise-greedily —
the audit-F3 lesson, applied from the start instead of learned again.

### The function-file/script-file collision, resolved by one rule

Octave's traditional model — one function per file, name bound to the
FILENAME — collides with `load_student()`. The runtime evaluates the
submission's text behind a `1;` guard instead of sourcing the file: a
flattened notebook, a hand-written script, and a pure function file all
register their definitions as command-line functions, the last under its OWN
name (a function file's internal name wins over its filename, which is what a
`require_fn("classify")` against a file called `submission.m` needs).
Verified: `source()` on a pure function file EXECUTES the body ('x'
undefined); the eval-with-guard defines it. Functions defined before a
mid-file error survive (R's loader also keeps later ones — a smaller promise,
stated in the runtime's header). Extracted notebooks stay clean cell text —
the reader prepends the guard, so `cellContains` sees exactly the cells.

### The per-kernel quirk budget: spent on nothing

Budget one quirk per kernel, said this document, and Octave's turned out to
be a pleasant zero: the standard xeus-6 boot sequence worked unmodified
(`needsPythonRuntime: false` — the env's Python payload is plotly's baggage,
never executed), no boot patch, no expression-yield, no stderr trap
(`fprintf(2, ...)` reaches the kernel stream directly), and `setenv` works so
the seed needs no overlay. A bare unmasked `exit(7)` does not even kill the
kernel — it raises "exit exception" internally ~5 s later and the session
survives — but masking is still mandatory because that path yields no usable
status. The mask is the third of its kind (R's `quit()`, Lua's `os.exit`);
`error("chickadee:exit", "%d", code)` carries the status on the error
IDENTIFIER, which a student's own `error("text")` (empty identifier) cannot
collide with. Isolation came almost free: the harness function's workspace
isolates each script's variables, leaving only `global`s to clear per run.

### Costs, measured

| | Octave | Lua | R | Python |
|---|---|---|---|---|
| env on disk | **142 MB** | 19 MB | 74 MB | 85 MB |
| kernel boot (Chromium, local disk) | **5–12 s** | 2.5–3.1 s | ~4.0 s | ~5.2 s |
| slowest smoke script | **89 ms** | 27 ms | seconds (attach) | ~1.1 s |
| per-statement floor | **none** (20 stmts = 1 ms) | none | ~180 ms/stmt | ~5 ms/cell |
| packages available | **none** | none | 51 | 48 |

The largest env of the four (the `octave` conda package alone is ~64 MB
compressed) and the slowest boot, in proportion — single runs ranged 5.0 s
(warm) to 12.1 s (cold-ish); treat the spread as the noise floor. "None" for
packages is again the correct answer: emscripten-forge carries no Octave
Forge packages, `pkg load statistics` fails cleanly ("package statistics is
not installed"), and the on-demand loop provably terminates with nothing to
install. The one native-side surprise: Ubuntu ships no CLI-only package —
`octave` hard-depends on the Qt5 stack even with `--no-install-recommends`,
so the interpreter costs ~338 MB installed on both images. Reported, priced,
accepted.

Found later (2026-10): the emscripten-forge `octave` build leaves out FFTW,
ARPACK, SuiteSparse, Qhull, GLPK, SUNDIALS, zlib, HDF5 and libsndfile. So
`fft`, `eigs`, sparse `chol`, `convhulln`, `glpk`, `ode15s` and `gzip`, among
others, fail in the browser but work on the native worker. The measured list
is in [authoring-parity.md](../authoring-parity.md#the-browser-octave-kernel-lacks-functions-that-native-octave-has).
For a new kernel, run `__octave_config_info__("build_features")` (or the
language's equivalent) in the browser and compare it with the native build.

## What the Java run actually cost

The seventh language, and the first added since this document was last revised —
so it is also the test of whether the runbook works. Short answer: the
compiler-named worklist held exactly, the invisible list caught two of its nine,
and the run found one defect class the document did not predict.

### The counts

| Pass | Layer | Sites |
|---|---|---|
| 1 | `Core` | 4 |
| 2 | `RunnerCore` + `Worker` | 5 |
| 3 | `APIServer` | 19 |
| 4 | `Tests` | 6 |

Twenty-eight compiler-named sites, plus one descriptor literal. Every one was
found by adding `case java` and rebuilding; none had to be looked for.

### What the invisible list caught

Two of the nine fired, both exactly as written:

* **Item 1 (the interpreter on the image)** — `default-jdk` on the application
  Dockerfile, the CI image, and three probe/apt pairs in `swift-tests.yml`. The
  conformance matrix names all five, so this was a failing test rather than a
  discovery.
* **Item 6 (capability matching, and specifically the probe's ARGUMENTS and
  OUTPUT FORMAT)** — `java -version` prints to **stderr** and **quotes** the
  number. It happens to parse, which is the dangerous kind of nearly-wrong;
  `javac --version` is the answer that does not depend on a tolerance. The
  deeper point is one the list does not make: the probe should name the binary
  that can be **absent**, and for Java that is the compiler, not the runtime. A
  JRE-only host advertises Java and then fails every test at exit 127.

Item 9 (do the generated scripts dispatch?) did not fire, because Java's
generated case is a `.sh` wrapper like C++'s. Items 2–5, 7 and 8 cost nothing:
the boolean sniffs are gone, the JS constants regenerate themselves, the MCP
surface is fully derived, and the submission policy is two one-token edits.

### The defect class the document did not predict

**A hardcoded `== .cpp` is not a C++ fact — it is a question about the language's
generated extension, asked badly.** Six sites spelled it the first way:

- the `generatedScriptExtension` uniqueness pin,
- the round-trip exemption in the conformance matrix,
- two resolution tests in `AssignmentLanguageTests`,
- the inputs-extension coupling in `LanguagePipelineWalkTests`,
- two `language == .cpp ? "cpp" : …` ternaries in `SubmissionPolicyTests`,
- and both submission-normalisation fixtures.

Every one of them silently answered "no" for a language that needed "yes". They
now read `LanguageDescriptor.generatesLanguagelessWrapper`
(`!scriptExtensions.contains(generatedScriptExtension)`), which is the fact they
were all approximating.

This is the same shape the document already names — "an arm is invisible to the
compiler when the next language arrives; a loop is not" — but one level down: not
a missing arm, a **present arm asking the wrong question**. A grep for the
neighbour's name (`grep -rn '== \.cpp' Sources/ Tests/`) is what finds it, and
it belongs beside the existing "search for the *default* rather than for the
language" advice under invisible item 5.

Two more defects fell out of the same run, both pre-existing and both invisible
until a second language shared an answer:

* **The notebook-check collision scan refused every check on every assignment.**
  It flat-mapped generated filenames across `allCases` without deduplicating, so
  two languages sharing a generated extension made one check collide with
  *itself*.
* **`differentialReferenceName` produced an illegal identifier.** It
  interpolated the function name directly; Java's targets are qualified, so it
  yielded `ck_ref_Solution.f` — uncompilable in the renderer AND undefinable by
  the instructor the save-time validator was telling to define it. Both halves
  read one property, so one fix closed both.

### What was genuinely per-language

Roughly 1,100 lines: the renderer and its nine kind bodies, `test_runtime.java`,
the personalization driver, the identifier helpers, and the execution suite.
That matches the document's own budget. The three traps that shaped it —
`System.exit` hijacking the exit code, type-strict boxed numeric equality, and
`CLASSPATH` replacing rather than extending the default — are in
[java-support.md](../java-support.md).

### One thing to carry forward

**The per-language quirk budget was spent, and on the native side.** R, Lua and
Octave each needed one kernel quirk; Java has no kernel and still needed one, in
the *shell wrapper*: a sentinel line proving the test ran to completion, because
a student's `System.exit(0)` otherwise reads as a pass. "Upload-only" removes
the kernel's quirks; it does not remove the language's. Budget one either way.
