# Design review: how Chickadee decides and applies "Python or R"

**What this is.** The second-opinion review requested by
[docs/language-handling-review-brief.md](language-handling-review-brief.md)
(PR #1234). It answers the brief's five questions (§6 there) and records what
the review found that the brief did not anticipate.

**Code reviewed:** `main` @ `d9c9777` (v0.4.660, 2026-07-29). Every claim below
was checked against source, not against the brief or `CLAUDE.md`; file:line
references are to that commit.

> **Outcome (2026-07-29).** The maintainer reviewed these verdicts and asked
> for the concrete items to land, including pulling the "on trigger" items
> forward. Implemented in the same PR as this document (#1235): the §1 hoist
> (`RunnerCore.extractR` + wasm bridge export + the browser stub deleted, with
> a fallback branch until the re-vendored artifact ships), the §2 generated
> fenced block (`scripts/generate-js-constants.sh` + CI check, replacing
> `r-kernel-names-drift.test.mjs` — action 7 pulled forward), the §3 surface
> shrink (kernel-name overload now internal to Core; the colliding `rederive`
> helper renamed), and the §4 consolidation (`AssignmentLanguage.scriptExtensions`
> / `init?(scriptExtension:)` routing the duplicated sniff sites; the
> boolean-shaped language tests converted to exhaustive switches). Actions 5–6
> (process rules, periphery pilot) remain open. Mechanism references in the
> body below describe the pre-PR state the review examined.

**Verdict in one paragraph.** The subsystem is in better shape than the brief
fears. The `AssignmentLanguage` enum-owns-its-strategy design is right and
should stay; the three resolution entry points are a real domain rule wearing a
slightly too-open API, not a design flaw; and the drift-guard "three
inventions" are guarding three genuinely different kinds of invariant, so they
do not want to be unified into one mechanism — they want a written decision
rule for which kind to reach for next time. Two concrete refactors are worth
doing (hoist R notebook extraction into RunnerCore; consolidate the
script-extension→language sniff, which is duplicated today in exactly the way
`rKernelNames` was before #1230), plus a handful of small hardening edits. The
most useful process change costs nothing: an abstraction and its adoption must
land in the same PR.

---

## 0. Corrections to the brief's premises

Findings that change the questions' framing. None invalidate a question, but
two answers depend on them.

**The brief's "deferred" list was already stale when it was written.** §5 of
the brief (echoing `CLAUDE.md` and the older `docs/r-support.md`) lists R
pattern-family / notebook-check renderers and literal-globals inlining into
hand-authored `.R` scripts as deferred. All three shipped in #1207
(2026-07-24, v0.4.636), five days before the brief:
`PatternFamilyRendererR.swift` (`renderRPatternCase` owns every kind in one
switch, plus `renderRExistenceGuard`), `NotebookCheckRendererR.swift` (nine of
the ten `NotebookCheckKind`s; `astStructure` is Python-only, gated by
`notebookCheckKindSupportsR`), and the R arm of
`TestScriptVariablePrepender.emit` / `applyForRawScript` (raw `.R` scripts get
`name <- <rLiteral>` preambles). `docs/r-support.md` has been updated;
`CLAUDE.md` still carries the stale claim today. That a status claim about
this subsystem drifted within five days, in the very document series that
frames the review, is the sharpest available evidence for question 5 — see §5.

**The reference count is 27, not 25.** Two files gained references between
`0665d75` and `d9c9777`. The census in §4 uses the current set.

**"Inert today" needs one qualifier.** The brief says the browser/worker R
extraction divergence is inert because the browser cannot run R scripts. True
for grading, but the browser's R extraction *path* is reachable:
`set_grading_mode` (and the manifest) accept `browser` for an R assignment
with no language guard, in which case `extractNotebookToMap` extracts the
notebook through the markerless `extractRCell` stub before every script
returns the WebR error and the v0.4.56 worker backstop picks the job up.
Nothing consumes the stub's output, so the brief's conclusion stands — but the
divergent code *runs* in a configuration instructors can reach, which is a
degree less inert than "unreachable" and strengthens the case in §1 for
deleting the stub rather than fencing it.

**The mechanism inventory is five, not three.** Besides the three the brief
tables, the same Swift↔JS / copy-sync problem is guarded by
`Tests/BrowserRunnerJSTests/grading-worker-drift.test.mjs` (fenced
`CHICKADEE_DRIFT:<name>:BEGIN/END` regions comparing
`browser-runner.js` ↔ `grading-worker.js`) and by
`Tests/WorkerTests/NotebookExtractorRCellMarkerTests.swift` (pins the marker
`extractNotebooksToCode` writes against the regex
`chickadee_student_cells()` splits on). The count matters for §2: five
mechanisms is past the point where "each reasonable alone" holds up, and the
fenced-region pattern in `grading-worker-drift` turns out to be the seed of
the right general answer.

---

## 1. Should R extraction live in RunnerCore? (brief §3.1)

**Recommendation: yes — option (a), and do it now, before WebR work starts.
It is small.**

What actually has to move is less than the brief implies. The worker's R
extraction is not a subsystem; it is the `else` branch of
`extractNotebooksToCode` (`Sources/Worker/NotebookExtractor.swift:139-147`):
trim each code cell, prepend `rCellBoundaryMarker(cellNumber:)`, join. It is
pure string assembly over the same `[NotebookCell]` input `extractPython`
already takes, with no Foundation dependency — exactly the shape RunnerCore
requires. Concretely:

- Add `extractR(cells:filename:)` to `Sources/RunnerCore/NotebookExtraction.swift`,
  returning the flattened marker-bearing source (header + markers + cells,
  byte-identical to today's worker output). Move `rCellBoundaryMarker` /
  `rCellBoundaryMarkerPattern` with it.
- The worker's `else` branch delegates, as the Python branch already does.
- Export it through the wasm bridge, and replace the browser's `extractRCell`
  loop (`Public/browser-runner.js:943-946` plus the `isR` branch of
  `extractNotebookToMap`) with a call to it. The stub is deleted.
- `NotebookExtractorRCellMarkerTests` keeps its job: the R grading runtime
  spells the marker regex literally (the `Tools/runner-support/test_runtime.R`
  byte-mirror cannot interpolate a Swift constant), so writer↔reader still
  need a pin. That test is load-bearing regardless of where the writer lives.

Why (a) over the alternatives:

- **(c) "add an R contract fixture now" is the wrong instrument.**
  `output-contract.json` pins output *interpretation*, which already runs
  through one shared implementation for both runners — R included (the wasm
  `executeSuites` path is language-agnostic; an R case there would exercise
  nothing R-specific). Extraction parity for Python was never achieved by
  fixture; it was achieved by sharing the implementation. A new fixture kind
  binding two extraction implementations is more of exactly the guard
  machinery §3.2 complains about, built to protect a duplication that can
  simply be deleted.
- **(b) "delete the stub until WebR is real" is acceptable but strictly worse
  than (a)** for nearly the same diff size. It removes the false parallel
  implementation but leaves R extraction native-only, so the WebR project
  starts by writing a JS extractor or doing the hoist under pressure — the
  drift-prone moment RunnerCore exists to prevent. Hoisting now means #77
  begins with extraction already shared and byte-stable, and the browser's
  extracted `.R` (which today can be produced in reachable configurations,
  see §0) matches the worker's from the first day.
- The "RunnerCore has no language concept" observation is not an obstacle.
  `extractPython` doesn't consume `AssignmentLanguage` and neither should
  `extractR`: which extractor to call is the *caller's* decision (worker:
  `manifestTargetsRSubmission` / kernel sniff; browser: `R_KERNEL_NAMES`).
  RunnerCore gains a second extraction function, not a language type. That
  keeps the enum in Core, where the resolution signals live.

Cost estimate: small — one Swift function move with tests, one wasm bridge
export, one browser call-site swap, one artifact re-vendor. The riskiest part
is remembering that worker-side extracted bytes must not change (regrades
compare against history); the function move is byte-preserving by
construction, and the existing `NotebookExtractorRCellMarkerTests` +
`WorkerTests` extraction tests pin it.

---

## 2. Does the Swift↔JS boundary want one mechanism instead of three (five)? (brief §3.2)

**Recommendation: no single mechanism — the five guards protect three
different kinds of invariant, and collapsing them would weaken the strongest.
What is missing is a written decision rule, plus one reusable pattern for the
weakest kind. Adopt "generate the copy" as that pattern the next time a
shared value-list changes; do not build it speculatively.**

The corrected inventory, by kind of invariant:

| Kind | Instances | Mechanism |
|---|---|---|
| Shared *behaviour*, one implementation | suite execution, output interpretation, Python extraction | RunnerCore compiled twice; `output-contract.json` asserts the two builds agree (native + real vendored wasm) |
| Mirrored *source*, two copies required | `test_runtime.py` / `.R` / `sitecustomize.py` embeds (Swift + JS); shared Python snippets between `browser-runner.js` and `grading-worker.js` | normalized-source comparison (`RuntimeSourceDriftTests.swift`, `runtime-drift.test.mjs`); fenced `CHICKADEE_DRIFT` regions (`grading-worker-drift.test.mjs`) |
| Mirrored *value / constant* | `rKernelNames` ↔ `R_KERNEL_NAMES`; cell marker ↔ runtime regex | textual parse of both sources (`r-kernel-names-drift.test.mjs`); writer↔reader pin (`NotebookExtractorRCellMarkerTests`) |

Read as a hierarchy, best to worst:

1. **Share the implementation** (RunnerCore/wasm). Strongest — drift is
   impossible, not detected. Use whenever the code is pure and
   embedded-safe.
2. **Generate the copy from the source of truth.** The copy exists but a
   machine writes it; CI asserts regeneration is a no-op. This repo already
   trusts this shape elsewhere: vendored artifacts + `check-pyodide-parity.sh`,
   the re-vendored wasm, `verify-jupyterlite.sh`.
3. **Behavioural contract fixture** (`output-contract.json`). For when two
   implementations must exist (different languages, different runtimes) and
   what must agree is observable behaviour.
4. **Normalized/textual source comparison.** Weakest — detects drift after
   the fact, breaks on reformatting, and asks a human to re-sync by hand.

Each existing guard sits on the highest rung available to it *except*
`r-kernel-names-drift.test.mjs`, which is rung 4 guarding a rung-2 problem: a
four-string constant. The fix is not a new grand mechanism; it is moving that
one guard up a rung when it next causes friction: a small script (the
`scripts/check-*.sh` family is the precedent) that writes the
`R_KERNEL_NAMES` block into `browser-runner.js` between fenced markers from
the Swift declaration, with CI asserting the regeneration produces no diff.
The regex-parsing fragility then lives in one generator rather than N tests,
and the browser copy stops being hand-maintained at all. For one
rarely-changing array, doing this today is not worth the build-plumbing —
which is why the recommendation is a trigger, not a task: **the next time a
constant or snippet becomes shared across the boundary, or the next time the
regex parse breaks on a reformat, build the generator and migrate
`rKernelNames` onto it.** In the meantime, write the hierarchy down (this
document serves) so the sixth mechanism is never a new invention.

One caution: do not try to fold the rung-3 fixture into a generator or vice
versa. `output-contract.json` survives implementation rewrites on either side
precisely because it pins behaviour, not source; that property is worth the
separate mechanism.

---

## 3. Is the three-entry-point resolution API the right shape? (brief §3.3)

**Recommendation: keep the three semantics — they encode a real precedence
rule — but shrink the public surface so the dangerous choice cannot be made
implicitly. No mode-enum parameter, no new types.**

What the call graph actually looks like at `d9c9777` (production code,
excluding tests):

- `resolve(for: setup, manifest:)` (the `APIServer` wrapper that reads the
  starter notebook) — **8 call sites**: `WorkerJobRoutes:316`,
  `BrowserRunnerRoutes:183`, `RunnerValidationHelpers:184`,
  `PatternFamilyApplication:318`, `GlobalInputsService:100`,
  `SectionInputsService:79`, `NotebookWorkingCopyStore:289`,
  `PreviewPersonalizationTool:125`.
- `rederive(manifest:notebookData:)` — **1 call site**,
  `manifestWithRederivedLanguage` (`ManifestFileHelpers.swift:227`), itself
  called from exactly one place: the notebook-replace path in
  `AssignmentAuthoringService:277`.
- `resolve(manifest:notebookKernelName:notebookLanguageInfoName:)` and the
  bare `resolve(manifest:)` spelling it enables via defaulted parameters —
  **0 external call sites**. Only Core's own `resolve(manifest:notebookData:)`
  uses them.
- The worker deliberately resolves nothing: it trusts `Job.language`
  (`RunnerDaemon+JobProcessing.swift:406`, `job.language ?? .python`), which
  the server stamped via the wrapper. This is a fourth entry point in effect —
  "the recorded answer travels with the job" — and it is the correct one for
  that boundary.

So the funnel the API *wants* already exists in practice; it is enforced by
doc comments (`docs/r-support.md`: "server-side callers should not reach for
it directly") rather than by the compiler. The brief's fear — "calling the
wrong one is silent" — is exactly the bug class that produced the wrapper in
the first place (a brand-new notebook assignment resolving `.python` and
sending an instructor's first R expression to `python3`). The cheap mechanical
fix follows from the zero-callers fact:

- **Make `resolve(manifest:notebookKernelName:notebookLanguageInfoName:)`
  internal to Core** (fold it into `resolve(manifest:notebookData:)` or mark
  it non-public). With it goes the defaulted-parameter spelling
  `resolve(manifest: props)`, which is the only truly dangerous form — the
  one that silently answers without a notebook. Every remaining public entry
  then states its notebook source explicitly at the call site:
  `resolve(for: setup, manifest:)` (setup knows its notebook),
  `resolve(manifest:, notebookData:)` (caller hands over bytes, `nil` is a
  visible statement), `rederive(manifest:, notebookData:)`.
- **Do not add a `LanguageResolution.authoritative / .rederived` parameter.**
  The precedence difference is not a flag on one algorithm; the two functions
  *consume different facts* (`rederive` must not even look at
  `manifest.language`). A mode parameter reintroduces a wrong-value axis on
  every call in exchange for removing a wrong-function axis on two — a bad
  trade against distinct, well-documented names. Distinct wrapper *types*
  fail the same test with more ceremony.
- Two naming nits worth fixing while touching this:
  `RestoreAssignmentVersionTool` has a private static `rederive(setup:testSetupsDirectory:)`
  (re-derives zip-derived files, nothing to do with language) — during this
  review a symbol search for language rederivation found it first. Rename it
  (`rederiveZipDerivedContent` or similar). And consider
  `rederiveIgnoringRecordedLanguage` as the public name if `rederive` ever
  gains a second caller; with one well-named caller
  (`manifestWithRederivedLanguage`) it is currently fine.

---

## 4. Adding a third language: how many of the 27 files change, and where is the seam? (brief §6.4)

Census of every `Sources/` file referencing `AssignmentLanguage`, bucketed by
what a third language demands of it.

**Bucket A — no change (11 files).** Resolve-and-carry sites that are already
language-generic through the enum: `Core/TestProperties.swift`,
`Core/Job.swift`, `Core/Models/RunnerCompatibility.swift`,
`AssignmentLanguageResolution.swift`, `GlobalInputsService.swift`,
`SectionInputsService.swift`, `NotebookWorkingCopyStore.swift`,
`PersonalizationSubstitution.swift`, `WorkerJobRoutes.swift`,
`BrowserRunnerRoutes.swift`, `PreviewPersonalizationTool.swift`. This bucket
is the payoff of the current design: the majority of the surface does not
know how many languages exist.

**Bucket B — one new switch arm, compiler-enforced (8 files).** Exhaustive
`switch` over the enum, no `default:` arms anywhere, so a third case fails
compilation at every site that needs an answer:
`AssignmentLanguage.swift` itself (`literal`, `inputsFileName`,
`generatedScriptExtension`, `renderInputsFile`),
`PatternFamilyRenderer.swift` (`renderCase`), `NotebookCheckRenderer.swift`,
`NotebookCheckKindHandler.swift` (identifier validation),
`TestScriptVariablePrepender.swift` (`emit`),
`PersonalizationEvaluator.swift` (driver + interpreter),
`RunnerDaemon+JobProcessing.swift` (via the enum's strategy members),
`ScriptInvocation.swift` (via `ScriptInterpreter`).

**Bucket C — the sites the compiler will NOT find (6 sites, the real
answer to "is the number acceptable").** Boolean-shaped language tests that
would silently lump a third language into whichever branch it falls:

- `NotebookExtractor.swift:123` — `language == .r ? "R" : "py"` (extraction
  output extension), and `:135` — `if language == .python { … } else { R markers }`:
  a third language gets R-style markers and the wrong mental model.
- `SubmissionStaging.swift:124` — same ternary for
  `legacyPreferredStudentModuleFilename`.
- `PatternFamilyRenderer.swift:135` — `if language == .r { R guard } else { Python guard }`:
  a third language gets Python bytes.
- `NotebookCheckValidator.swift:39` — `if language == .r, !notebookCheckKindSupportsR(…)`:
  a third language skips kind-support validation entirely.
- `PersonalizationEvaluator.swift:163` — `if language == .python { PYTHONPATH }`
  is genuinely Python-specific and fine; listed for completeness.

These should become exhaustive switches **now** (a mechanical, behaviour-free
edit), so that "add a case, follow the compiler" becomes literally true. That
is the honest answer to the brief's question: 27 files is fine *if and only
if* the compiler produces the worklist, and today it produces all of it
except these six lines.

**Bucket D — irreducible per-language work (new artifacts, not edits).** No
seam removes these; they are the feature: a `JSONValue.<x>Literal` renderer,
a `PatternFamilyRenderer<X>.swift`, a `NotebookCheckRenderer<X>.swift` +
kind-support gate, a personalization driver + seed runtime (the
`RPersonalizationRuntime` analog, including whatever the language's
no-bignum answer is), a grading runtime (`test_runtime.<x>` — canonical file,
Swift embed, browser embed, two drift tests), an extraction branch, runner
capability strings, and a browser execute-or-clear-error path. #1207's R
renderer series is the template and the effort yardstick.

**The seam that is missing — and it is this review's second concrete
refactor: the script-extension→language mapping is duplicated today in
exactly the pre-#1230 `rKernelNames` shape.** "`.r` means R" is hand-inlined
at (at least): `AssignmentLanguage.swift:43-45` and `:133-135` (resolve and
rederive), `SubmissionStaging.swift:184-193` (`manifestTargetsRSubmission`,
plus the `.py` checks), `SubmissionStaging.swift:120` (`ext == "py" || ext == "r"`),
`TestScriptVariablePrepender.swift:147-150` (`applyForRawScript`), and — as
strings with different semantics but the same maintenance surface —
`RunnerCore/ScriptClassification.swift:35` and the browser's
`scriptExtension` checks. Give `AssignmentLanguage` an
`init?(scriptExtension:)` / per-case `scriptExtensions` set and route the
Swift sites through it, before any third language and ideally before the
next R fix touches those files. This is the same consolidation #1230 did one
layer up, done this time *before* five copies become the bug. (A related
observation, filed as a footnote rather than a task:
`ScriptClassification.interpreterFromShebang` has no `Rscript` entry, so an
extensionless R script with an R shebang classifies as `.unknown`. Harmless
today — instructors upload `.R` files — but it is a latent asymmetry in the
same family.)

Also outside the compiler's sight, for the eventual third language: the
kernel-name concept is currently an R-specific static (`rKernelNames`); a
third *notebook* language generalizes it to per-language sets. And the
non-Swift edges — `R_KERNEL_NAMES` in JS, requirement strings in
`AssignmentRequirementHelpers`, MCP tool descriptions that say "Python or R"
— are a checklist, not a seam; keep them in this document's orbit.

---

## 5. What would have caught a "single source of truth" with zero callers? (brief §6.5)

Ranked by value per unit cost:

**1. A definition-of-done rule, free: an abstraction and its adoption land in
the same PR.** The `rKernelNames` failure was not a detection failure; it was
a sequencing decision. The constant landed (R-support work) with its
migration deferred, and deferred-forever is the default fate of migrations
nobody is forced to finish. The rule: a PR that introduces a canonical
helper/constant *must* migrate every existing site it canonicalizes, in the
same diff — otherwise the doc comment may not say "single source of truth",
it must say "not yet adopted by X and Y". This is enforceable in review with
zero tooling, and it is the only measure on this list that prevents rather
than detects.

**2. Extend the same rule to prose: shipping a deferred item includes
deleting the deferral claim.** The live counterexample is in §0: `CLAUDE.md`
still says the R renderers are deferred, five days after #1207 shipped them,
in the document every fresh session reads first. Same failure shape as the
zero-caller constant — a truth claim with nothing binding it to the code. A
grep for the feature's name across `docs/` + `CLAUDE.md` belongs in the
shipping PR. (This review's PR fixes the two stale `CLAUDE.md` lines it
found.)

**3. A scheduled dead-symbol scan, worth a pilot with explicit kill
criteria.** [Periphery](https://github.com/peripheryapp/periphery) would have
flagged `rKernelNames` as a public declaration with no external references.
Run it as a weekly scheduled job (not per-PR: whole-project builds and a
baseline file for Vapor/Fluent reflection false positives make it too noisy
for the merge path), triaging its report into "dead — delete" vs "aspirational
— adopt or demote". If a month of reports produces more baseline entries than
findings, drop it without ceremony.

**4. Not worth it: a bespoke lint rule** ("flag `Set<String>` literals that
look like kernel lists", "flag constants named `*Names` with one reference").
The class is too irregular; every variant is a new rule with new false
positives. The general form of the problem is what periphery does; the
specific form is what rule 1 prevents.

---

## 6. The "load-bearing, do not tidy" list (brief §4) — reviewed and extended

All four of the brief's entries were verified and hold. In particular the
`generatedScriptExtension` non-reuse comment is present and correct at
`NotebookExtractor.swift:119-122`, and nothing in this review's
recommendations touches generated-script bytes, `spec_hash` inputs, or
`TestSetupCache` keys (the §1 hoist moves *extraction* code, which is
deliberately outside that constraint; the §4 extension-map consolidation must
route the *sniff* sites through one symbol without changing any emitted
filename).

Two entries to add to the list:

- **`job.language ?? .python` (`RunnerDaemon+JobProcessing.swift:406`) is a
  wire-compat default, not a style choice.** A payload from an older server
  omits `language`; `.python` preserves legacy behaviour. Do not "clean it
  up" to non-optional.
- **`testRuntimeR` interpolates `AssignmentLanguage.r.inputsFileName`
  (`TestRuntimeSources.swift:546`) while `Tools/runner-support/test_runtime.R`
  spells the literal.** The byte-for-byte mirror invariant still holds after
  interpolation, and `RuntimeSourceDriftTests` proves it — but it means the
  embed and the canonical file are *not* textually identical sources, so a
  well-meaning "make them identical" edit in either direction has a drift
  test waiting for it.

---

## 7. Recommended actions, in order

| # | Action | Size | When |
|---|---|---|---|
| 1 | Convert the six boolean language tests (§4 bucket C) to exhaustive switches | S | Any time; pure hardening |
| 2 | Consolidate the script-extension→language sniff into `AssignmentLanguage` (§4) | S | Before the next change that touches those sites |
| 3 | Hoist R extraction into RunnerCore, wasm-export, delete `extractRCell` (§1) | S–M | Before any WebR (#77) work begins |
| 4 | Make the kernel-name `resolve` overload non-public; rename the colliding `rederive` helper (§3) | S | With #3 or standalone |
| 5 | Adopt the same-PR adoption rule + docs-grep-on-ship rule (§5) | — | Team agreement; note in CLAUDE.md |
| 6 | Pilot a weekly periphery scan with kill criteria (§5) | M setup | Optional; low priority |
| 7 | Migrate `rKernelNames` to a generated fenced block (§2) | M | Only on trigger: the list changes or the regex test breaks |

Explicitly *not* recommended: a unified drift mechanism replacing the
existing five guards (§2); a `LanguageResolution` mode enum or wrapper types
(§3); an R case in `output-contract.json` for extraction parity (§1 — share
the implementation instead); any speculative generalization of the enum
beyond the seam fixes above (§4 bucket D is real per-language work no
abstraction removes).
