# Adding Octave, then C++: two briefs

*Written 2026-08-07, after the Lua audit series (#1283–#1287). Hand either half
to an agent as its task. Both assume
[docs/adding-a-xeus-kernel.md](adding-a-xeus-kernel.md) is read first — that
runbook **is** the plan; this document only carries what is specific to these two
languages, and what the runbook cannot know about them.*

**Stage them in this order, and the order is load-bearing.** Octave is a normal
fourth language: it fits the existing model, and the interesting part is a
handful of Octave-shaped traps. C++ does **not** obviously fit the model at all,
and its first deliverable is a decision, not code. Doing Octave first means the
model has been proven on a fourth language before C++ asks whether the model
applies.

---

## Why these two, and what each one actually tests

| | Octave | C++ |
|---|---|---|
| kernel / size | `xeus-octave` 66.9 MB — the largest | `xeus-cpp` 24.1 MB |
| xeus ABI | 6.0.2 (our pin: 6.0.5) | 6.0.3 |
| interpreted? | yes | **no** — crosses the axis the model cannot represent |
| dynamically typed literals? | yes | **no** — crosses the other one |
| fits `ScriptInterpreter`? | yes: a file handed to `octave` | **no** — see the C++ brief |
| teaching case | MATLAB-adjacent; numerical methods, signal processing, engineering | large and obvious |
| already gradeable today? | no | **yes**, via a `.sh` suite + `TestProperties.makefile` |

Octave is the language the `ModuleResolution` scorecard was written against: it
is the reason `workingDirectoryIsOnDefaultSearchPath` exists as a separate fact
(file-resolved in spirit like R, yet it *does* need `OCTAVE_PATH`). Adding it
tests a prediction the design already made in writing.

## Who pays for a new kernel — read this before the size scares you

It is easy to misread CLAUDE.md's "**boot** … is paid by everyone on every
notebook open" as meaning a new *language* taxes every student. It does not, and
the distinction matters when weighing a 66.9 MB kernel:

- That sentence is about **packages inside one env** — adding `ggplot2` to
  `environment-r.yml` makes every *R* boot pull it "whether or not they touch the
  package". That is why the envs are **separate on purpose**, and why
  `check-xeus-vendored.sh` asserts they stay distinct.
- A new *language env* is isolated by construction.
  `RoutingExecutor.ensureReady()` in `Public/browser-runner.js` computes
  `requiredKinds()` from the assignment's own manifest scripts and starts only
  those substrates — "an R lab never boots the Python kernel and a Python lab
  never fetches the 74 MB R environment". On the editor side a notebook carries
  one kernelspec, so JupyterLite attaches one kernel.

So the 66.9 MB is paid by students **on an Octave assignment**, which is the
right shape: the cost falls on the people getting the value. What a new kernel
does cost everyone is ~100 MB of vendored bytes in the repo and Docker image,
build time, and ABI-pin maintenance — plus one small `<script>` tag on the
notebook page, which is kilobytes.

Weigh the size against maintenance and image bloat, then — not against student
boot time for unrelated courses.

---

# Brief 1 — Octave

## Step 0: the native interpreter

Instructor validation is enqueued as a `kind == .validation` submission and is
graded by the **native worker**, even for a browser-graded assignment. The
interpreter must be on the runner image (`Dockerfile`) or nothing validates —
that is the exit-127 class, and it shipped once with Lua.

Check the installed size of `octave-cli` (not full `octave`, which drags in a GUI
stack) before committing. It is far lighter than a Haskell toolchain and far
heavier than `lua5.4`. Add it to **both** the runner `Dockerfile` and
`.github/docker/ci-image/Dockerfile`, plus the per-job apt fallback in
`swift-tests.yml` — the CI image is a separate file and forgetting it makes every
execution test skip **silently** (audit F2).

## The four Octave-shaped traps

These are the ones worth knowing before writing the renderer. Each is a place
where Octave will accept something and mean the wrong thing.

**1. A heterogeneous literal does not error — it silently becomes a char array.**
This is the most dangerous item in this document. `[1, "two"]` in Octave does not
fail; `[` concatenates, converting numbers to characters by code point, so
`[65, "bc"]` is the string `"Abc"`. A `JSONValue` array rendered naively into
`[...]` therefore produces a plausible value that is silently wrong, and a
generated test would compare against it and award marks on that basis.

The correct rendering is a **cell array**: `{1, "two"}`. Decide the rule
explicitly in `JSONValue.octaveLiteral` and write it down — the obvious one is
*homogeneous numeric → `[...]`, anything else → `{...}`* — and make
`chickadee_equal` handle both shapes. Note this is the opposite failure mode from
the statically typed languages, where the impossibility is loud.

**2. Everything is a matrix, and `==` is element-wise.** `1` is a 1×1 double.
`a == b` on arrays yields an array of logicals, not a scalar, so
`if a == b` is not the comparison you want. `isequal(a, b)` is. Build
`chickadee_equal` on `isequal`, and be deliberate about the integer/double
question the way Lua had to be (`1` vs `1.0`) — audit F3 is the cautionary tale:
a second, weaker notion of equality living beside the real one disagreed with it
in both directions.

**3. Function files vs script files.** Octave's traditional model is one function
per file, with the function name matching the filename. That collides with the
shape `test_runtime.<x>` uses elsewhere — `load_student()` returning an
environment you then pull several functions out of. Modern Octave allows several
functions in one file and `source`-ing, but decide the contract deliberately and
state it in the runtime helper's header comment. This directly shapes
`student_file()` / `require_fn()`.

**4. `exit` must be masked in the kernel.** This is the third time: R's `quit()`
and Lua's `os.exit` both had to be masked so `test_runtime` stays byte-identical
across the native runner and the kernel. A kernel has no process to exit. If it
regresses, every test reads as a pass. Expect the same for Octave's `exit`/`quit`
and budget for it.

## Which kinds Octave supports

Answer all 8 `PatternKind`s and all 10 `NotebookCheckKind`s explicitly, and
**refuse the unsupportable ones at save time** with a message naming what *is*
supported — the precedent is Lua refusing `cellContains` with `regex: true`.
Refusing beats approximating: an approximation awards or withholds marks on a
false basis.

Expected differences from Lua, to verify rather than assume:

- `figureCount` may genuinely **work** — Octave has plotting, where Lua had none.
  Confirm what `xeus-octave` actually supports in wasm before promising it.
- The four data-frame kinds have no clean Octave analogue (MATLAB `table` support
  in Octave is limited). Likely refuse, but check.
- `astStructure` stays Python-only, as for R and Lua.
- Octave's regex is PCRE-ish (`regexp`), so `cellContains` with `regex: true` may
  be supportable — unlike Lua patterns. Verify; do not assume.

## The prediction to check

`supportFilesPathEnvironmentVariable` should come out as `OCTAVE_PATH`, from
`moduleResolution: .byName(searchPathVariable: "OCTAVE_PATH")` plus
`workingDirectoryIsOnDefaultSearchPath: false`. Verify the second empirically —
`octave-cli --eval "path"` — rather than assuming. If it comes out `true`, the
scorecard in `Sources/Core/LanguageDescriptor.swift` is wrong and should be
corrected, which is a finding worth reporting on its own.

---

# Brief 2 — C++

## This brief's first deliverable is a decision, not code

Do not start by writing a renderer. Start by answering: **does C++ want the
authoring surface at all?**

Chickadee grades C++ **today**, with no work: an instructor writes a `.sh` suite
script, uses `TestProperties.makefile` for the build step, and the runner
executes it. None of `AssignmentLanguage` is involved. That path already exists
and already works.

What becoming an `AssignmentLanguage` adds is *authoring*: generated pattern
families, notebook checks, per-student personalization, and an in-browser kernel.
What it costs is roughly 1,000 lines of renderer, a vendored kernel, a compiler
on the runner image, and permanent maintenance.

So the question for the course is narrow: **do you want generated test families
and personalization for C++, or do you want to grade C++ assignments?** If the
latter, the answer is "use a `.sh` suite and a makefile" and this brief ends
here. Write that conclusion down — "this language should not be an
`AssignmentLanguage`" is a legitimate, cheap, and useful outcome.

## Why C++ does not fit the current model

Concretely, not abstractly. In `Sources/Worker/ScriptInvocation.swift` every
`ScriptInterpreter` case resolves to `envInvocation(interpreter:script:)` — hand
one **file** to one **command**. Python, R, Lua, ruby, perl, node, php all fit.
C++ cannot: it needs compile-then-link-then-run. `interpreterProbe` has the same
assumption baked in — it is a command you hand a file to, and for C++ it would
have to mean a compiler.

`TestProperties.makefile` is exactly the seam that exists for this, and it sits
*outside* `AssignmentLanguage` on purpose.

Two further mismatches, both documented in the runbook and both real:

- **No import.** Chickadee's model is "the test script imports the student's
  module". A C++ test must `#include` the student's source into the session.
  Workable, but it lands on `test_runtime.<x>` and `SubmissionNormalizer` rather
  than on the substrate, and it changes what "the student's module" means.
- **Statically typed literals.** `literal(_:)` renders a `JSONValue`, which is
  dynamically typed. `[1, "two"]` has **no** C++ rendering. Unlike Octave, this
  fails loudly rather than silently — which is better — but it means several
  pattern kinds must refuse heterogeneous cases at save time, and `expected`
  needs a decided type story (`auto`? a template? one type per family?).

## If the decision is to proceed

- **The browser half is the easy half.** `xeus-cpp` depends on `cppinterop`
  (the Clang-REPL layer that succeeded cling), so C++ genuinely is interactive
  there, and Chickadee only needs "run this file, report an exit code" — which is
  what we already do by wrapping a file in one cell.
- **The native half is the hard half.** It needs a compiler on the runner image
  and a compile step before execution. Decide whether that runs through the
  existing `makefile` support or through a new invocation shape, and prefer the
  existing one.
- **Settle the pedagogical question first.** An interpreter is not a compiler.
  Code that only fails at link time, or that depends on separate compilation,
  behaves differently under Clang-REPL than under the course toolchain. For a
  course whose *point* is C++, "it worked in the browser" diverging from "it
  compiles with `g++`" is a teaching problem no amount of substrate work removes.

---

## What is already true for both (do not redo)

The Lua series left the model in a better state than the runbook's history
implies:

- `LanguageDescriptor` is one struct literal per language; the initialiser will
  not compile until every fact is answered.
- Derived rather than enumerated: the vendored JupyterLite kernel
  (`normalizeNotebookForJupyterLite` iterates `allCases`), `contentType(for:)`,
  and the three module-resolution projections.
- `scripts/generate-js-constants.sh` generates the browser's kernel-name sets
  **and** the graded-script extension list, and fails when a fenced block is
  missing.
- `LanguagePipelineWalkTests` walks manifest → resolve → renderers → inputs file
  → editor kernel per language; `LanguageConformanceMatrixTests` covers the
  per-stage matrix. Both iterate `allCases`, so both fail for a new language
  until it genuinely works.

The remaining per-language work is the renderer (~1,000 lines), the runtime
helper, the kernel env, the interpreter on two Dockerfiles, and one per-kernel
quirk — expect a *different* quirk than R's or Lua's, since R's two expensive
lessons did not generalise to Lua.

## Done test

The checklist at the end of [docs/adding-a-xeus-kernel.md](adding-a-xeus-kernel.md).
In particular: **execute** the generated scripts against a correct submission
*and* a wrong one, and confirm the executed half of the conformance matrix did
not skip. A parse-only check passes on code that cannot grade — a `#`-commented
Lua inputs file parsed fine by shebang accident and would have zeroed every
per-student value.
