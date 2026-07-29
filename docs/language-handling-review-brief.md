# Design-review brief: how Chickadee decides and applies "Python or R"

**Purpose.** A second-opinion review of the language-dispatch surface, to decide
whether it wants a structural refactor. Written after PR #1230, which fixed one
layer of duplication and surfaced the questions below.

**Status of the code as of this brief:** `main` @ `0665d75`.

---

## 1. What the subsystem does

An assignment is authored and graded in exactly one language, Python or R. That
choice drives: which literal syntax renders per-student values, which per-student
inputs file is written (`_ck_inputs.py` / `_ck_inputs.R`), which interpreter
evaluates instructor expressions, which extension a notebook is extracted to, and
which runtime helpers get staged.

The choice is modelled by `AssignmentLanguage` (`Sources/Core/AssignmentLanguage.swift`),
a 2-case enum that also carries its own per-language behaviour (`literal(_:)`,
`inputsFileName`, `generatedScriptExtension`, `renderInputsFile(_:)`). That part is
good and should probably survive any refactor: a closed enum owning its variants
beats a protocol with two conformances here.

**Scale:** 25 files under `Sources/` reference `AssignmentLanguage`.

---

## 2. What PR #1230 just changed

The R kernelspec alias set (`ir`, `r`, `webr`, `xr`) was hand-inlined at **five**
sites across two languages, even though `AssignmentLanguage.rKernelNames` existed
and its own doc comment declared itself "the single source of truth for the
detection currently duplicated in…". **It had zero callers outside its own file.**

Now: one detector, `AssignmentLanguage.isRNotebookMetadata(_:)`, with all Swift
callers routed through it — `rederive`, the worker's `submissionIsRNotebook` and
`extractNotebooksToCode`, `AssignmentRequirementHelpers.scanNotebook`, and
`normalizeNotebookForJupyterLite`. `extractNotebooksToCode`'s `forcedLanguage` went
from `String?` (carrying `"r"` / `"python"`) to a typed `AssignmentLanguage?`. The
browser's unavoidable copy is named `R_KERNEL_NAMES` and pinned to the Swift set by
`Tests/BrowserRunnerJSTests/r-kernel-names-drift.test.mjs`.

**The interesting part is not the fix, it's the failure mode:** the codebase already
had the right abstraction and did not use it. The constant was introduced by the
R-support work; the older call sites predated it and were never migrated, and
nothing detected that. A review should ask what would have caught this.

---

## 3. The open structural questions

### 3.1 RunnerCore's parity guarantee stops at Python

`RunnerCore` exists so the native worker and the in-browser runner "run one
implementation and cannot drift" (CLAUDE.md). That guarantee is real for suite
execution and output interpretation: `Tests/Fixtures/output-contract.json` pins
them, asserted against both the native build and the *real vendored wasm*.

It does not extend to R:

- `RunnerCore.extractPython` is Python-only, by name and behaviour. RunnerCore
  contains **no** language concept at all (PR #1230 deleted an unused
  `NotebookLanguage` enum that was the only mention).
- R notebook→source extraction exists in two places:
  - `Sources/Worker/NotebookExtractor.swift` — emits `# ---- chickadee:cell N ----`
    boundary markers that the R runtime's `chickadee_student_cells()` splits on.
  - `Public/browser-runner.js` `extractRCell` — a stub that trims whitespace and
    emits cells verbatim, with **no** markers.
- `output-contract.json` contains zero R cases. No test binds these two.

**This is not an active bug.** The browser cannot run R test scripts at all — it
returns `'R test scripts require WebR — not yet supported'` (issue #77). So the
divergence is inert today. It is a *latent* one: when WebR lands, someone must
reconcile a marker-emitting Swift extractor with a verbatim JS stub, and nothing
in CI will tell them the two disagree.

**Question for review:** is the right answer (a) hoist R extraction into RunnerCore
so the wasm serves both, matching the Python design; (b) delete the browser's R stub
until WebR is real, so there is one implementation rather than one-and-a-half; or
(c) leave it and add an R contract fixture now, so the reconciliation is test-driven
when it happens?

### 3.2 Three ad-hoc mechanisms guard one Swift↔JS boundary

The browser cannot import Swift, so every shared invariant needs a hand-built guard.
There are now three, all different:

| Invariant | Mechanism |
|---|---|
| Output interpretation | `output-contract.json` fixture, driven through native **and** real wasm |
| Embedded Python runtime helpers | `runtime-drift.test.mjs` + `RuntimeSourceDriftTests.swift` — normalized source comparison |
| R kernel alias list | `r-kernel-names-drift.test.mjs` — textual parse of both source files (added by #1230) |

Each is reasonable alone. Collectively they are three inventions for one problem,
and the third is the weakest — it regex-parses Swift source, so it breaks if the
declaration is reformatted.

**Question for review:** does this boundary want one principled mechanism — a
codegen step emitting a JS constants module from the Swift declarations, or a
single shared contract format — instead of a new bespoke test each time something
becomes shared?

### 3.3 Three resolution entry points with deliberately different precedence

- `resolve(manifest:notebookKernelName:notebookLanguageInfoName:)` — manifest's
  recorded language wins.
- `resolve(manifest:notebookData:)` — same, but sniffs the notebook when the
  manifest is silent.
- `rederive(manifest:notebookData:)` — **deliberately ignores** the recorded
  language, because a recorded value is a sticky memo that would otherwise make a
  Python→R conversion a one-way door.

The distinction is a genuine domain rule and the doc comments explain it well. But
it is expressed as three similarly-named statics on one type, and calling the wrong
one is silent — you get a plausible answer that is stale.

**Question for review:** is there a shape that makes the choice explicit at the call
site (e.g. an explicit `LanguageResolution.authoritative` / `.rederived` parameter,
or distinct types) rather than relying on the caller picking the right overload?

---

## 4. Things that look wrong but are load-bearing — please don't "fix" these

- **`AssignmentLanguage.generatedScriptExtension` is deliberately not reused** for
  notebook-extraction output, even though both map python→`py`, r→`R`. That property
  is scoped to *generated* scripts whose filenames feed `spec_hash` and
  `TestSetupCache` keys; coupling extraction to it would let a change in one silently
  move the other. There is a comment saying so at the extraction site.
- **`.python` is the default at every call site** so existing Python assignments
  render byte-for-byte identically. Any refactor must preserve generated bytes —
  `spec_hash` and the runner-side cache key both derive from them.
- **`TestProperties` still mirrors legacy arrays on write.** Scheduled for the v0.7.0
  cleanup (currently 0.4.656); it is back-compat for readers predating `testItems`.
- **Base R has no bignum**, so the personalization seed is a Horner-fold reduction
  shared by the server driver and the grading runtime specifically so they cannot
  drift (`RPersonalizationRuntime.chickadeeSeedRSource`).

---

## 5. Related known-deferred work (context, not scope)

- `docs/r-support.md` — literal-globals inlined into hand-authored `.R` scripts, and
  R pattern-family / notebook-check renderers, are both deferred.
- `docs/personalization-eval-runtime.md` — expression evaluation currently spawns
  `python3` / `Rscript` **on the server**; the documented direction is to move it to
  the runner/browser per-language. That would change who needs a language concept.
- Issue #77 — WebR in the browser runner, the gate on §3.1.

---

## 6. What a good review would answer

1. Should R extraction live in RunnerCore (§3.1), and if so is that worth doing
   before WebR forces it?
2. Does the Swift↔JS boundary want one mechanism instead of three (§3.2)?
3. Is the three-entry-point resolution API the right shape, or should the
   authoritative-vs-rederived choice be explicit in the type system (§3.3)?
4. Adding a third language (the enum is closed at 2): how many of the 25 files
   would have to change, and is that number acceptable? If not, what's the seam?
5. What process change would have caught a "single source of truth" constant sitting
   with zero callers? A lint rule, a review checklist, or nothing worth the cost?
