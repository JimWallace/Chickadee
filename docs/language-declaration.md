# Assignment language: declared, not inferred

Where the multi-language transition stands as of v0.5.59 (#1330, #1331), what
the rule now is, and what became of the fourteen call sites that were still
answering a different question.

---

## The rule

**Every assignment declares its language. Nothing infers one.**

`AssignmentLanguage.resolve(manifest:)` returns `manifest.language` and nothing
else. There is no extension sniff, no kernelspec read, no `.python` tail. A
call site that wants to know an assignment's language reads the declaration.

`manifest.language` is an `Optional<AssignmentLanguage>`, and the Optional is
load-bearing: **nil means the author said "none"**, which is a real and
supported state — a suite of plain `.sh` scripts. It does not mean "nobody has
been asked", because `languageDeclared` records that the question has an
answer, and `BackfillDeclaredLanguage` stamped it on every assignment that
predates the rule.

Conflating those two states is where every silent misroute in this arc came
from. When resolution ended in `?? .python`, "the author chose Python" and "we
guessed Python because nothing said otherwise" were the same value, so a Lua
assignment resolved to Python, an R author's first `=` expression went to
`python3`, and the browser wrote `_ck_inputs.py` for an R runtime — each of them
type-checking perfectly and failing at the student.

### Do not reintroduce inference

If a call site does not know the language, the answer is to make the author
declare it, not to work it out from content. Content is content: a `.R` file in
the suite, an `xr` kernelspec in the starter notebook, and a `library(dplyr)`
call are all things an assignment may contain without being an R assignment.

Two guards hold the line mechanically:

- `scripts/no-language-defaults.sh` (wired into the `format-lint` CI job) fails
  on any `language:` parameter with a default value. Seventeen functions had
  one, and that is what made both #1330 defects possible — an omitted argument
  produced a confident wrong answer instead of a compile error. A caller that
  means Python now says so.
- `AssignmentLanguageTests` runs `allCases`-driven assertions: every language
  must resolve from its own graded script and its own notebook kernel, so a
  seventh language cannot silently fall through to Python.

Two shapes are deleted rather than kept for convenience, because both are
invisible to the compiler:

- `isRNotebook(_:)` / `isRNotebookMetadata(_:)` — a `Bool` return invites
  `isRNotebook(nb) ? .r : .python`, which type-checks forever however many
  languages exist and routes all the others to Python.
- `rederive(manifest:notebookData:)` — re-derivation that ignored the recorded
  language, so replacing a starter notebook changed the assignment's language
  under its author. It existed because the recorded value was a *memo* of what
  resolution last computed, and a memo goes stale. A declaration does not.

---

## Who declares

Four doors create an assignment, and all four answer the question:

| Door | How |
|---|---|
| Web create page (`POST /instructor/new`) | `required` `<select name="assignmentLanguage">`, with an explicit **None** option; declared *before* the draft service runs, so families authored in the same save render in the chosen language |
| MCP `create_assignment` | required `language` argument |
| REST zip upload (`POST /api/v1/testsetups`) | `derivedDeclaration` at the boundary, recorded immediately |
| Course-bundle import | `derivedDeclaration` at the boundary, recorded immediately |

Plus two paths that change an existing declaration:

- Web edit save (`PublishedAssignmentRoutes+SaveEdit`) — refuses a change once
  generated scripts exist, because changing the language rewrites every
  generated filename.
- MCP `set_assignment_language` — same guard.

All of them go through `declareManifestLanguage(setup:to:on:)`
(`Helpers/ManifestFieldEdits.swift`), which is the only writer. It sets
`languageDeclared`, writes or removes `language`, and — for an `.uploadOnly`
language — moves `submissionMode` and `gradingMode` with it, so creation cannot
produce the incoherent `uploadOnly` + `browser` pair.

### The one remaining sniff

`AssignmentLanguage.derivedDeclaration` is derivation, deliberately not named
`resolve`. Three callers, all boundaries where content arrives with no author
answer attached:

1. the REST zip upload,
2. course-bundle import,
3. `BackfillDeclaredLanguage` (one-time).

Each **records the result immediately**, so the guess is made once and becomes a
declaration. Precedence is the old resolution order — a graded script's
extension in `allCases` order, then the starter notebook's kernel, then nil — so
what gets written down matches what the system used to compute on the fly.

It is a boundary step, not a resolution strategy. Do not call it from a read
path.

---

## The `?? .python` sites

There were fourteen. Five are gone; ten lines remain and are correct as they
stand.

These are **not** resolution fallbacks. Resolution has no fallback. They are
sites asking a different question:

> This operation needs a language, and the assignment declares none. Now what?

They divide into four groups, and the decision rule that separates them is:

**Fail loudly while authoring. Never fail while grading, rendering a page, or
extracting a student's submission.**

An author can fix a missing declaration in ten seconds and a refusal tells them
how. A student cannot fix it at all, and a refusal on their path turns an
instructor's omission into a failed submission.

### Group 1 — authoring: refuse. **Done.**

The justification written at these sites ("refusing would be circular — a
pattern family is frequently the FIRST thing authored, and generating its
scripts is how the suite acquires a graded script") was written **under
inference**, when nil genuinely meant "nothing has named a language yet". It is
dissolved by declaration: creation always declares, so nil at these sites means
the author chose *None*, and authoring a Python pattern family on an assignment
whose author said it has no language is the exact silent-wrong-answer shape this
arc removed.

| Site | Now |
|---|---|
| `PatternFamilyApplication+Inputs.swift` | Returns the declaration, optional. `applyPatternFamilies` refuses (`undeclaredLanguageGenerationMessage`) when the save would generate a script |
| `GlobalInputsService.swift` | Refuses an `=` expression (`undeclaredLanguageExpressionMessage`); literal variables are unaffected |
| `SectionInputsService.swift` | Same, for section variables |

Two properties of the pattern-family refusal are load-bearing:

- **It is conditional on generation.** Every suite save runs through
  `applyPatternFamilies`, including saves that only reorder raw scripts, so an
  unconditional refusal would make a plain `.sh` suite uneditable. The guard
  fires only when there is an enabled family case or a notebook check to render.
- **It is not the whole bug.** The fallback was also *writing Python down*:
  `rebuildPatternFamilyManifest` always records the language it is handed, so
  reordering two `.sh` scripts silently rewrote a declared-None assignment's
  declaration to Python. The manifest rebuild now takes an optional and persists
  nil.

The inputs services refuse inside `evaluateForActingSeed`, which despite the
name is reached only from `apply` — the save. Notebook substitution at student
first-open (`PersonalizationSubstitution.resolve`) keeps its stated default and
never refuses.

### Group 2 — stop naming a language at all. **Done.**

`UpdateSolutionTool` asked two questions through one `?? .python`:

- *Is this language upload-only?* — answered now by
  `if case .uploadOnly = language?.editorSupport`, with no default: a
  declaration of "none" is not upload-only, so the notebook workflow is kept
  exactly as before.
- *Is this solution filename's extension acceptable?* — a real language
  question, and the old fallback answered it as Python, so a `.sh`-suite
  assignment accepted `solution.py` and rejected everything else for a reason
  nothing in the assignment supported. It refuses now, naming
  `set_assignment_language` as the fix.

### Group 4 — "none" is a real answer here. **Done.**

`shellTestScript` renders the three `.sh` scaffolds. Its nil case fell back to
Python, which was defensible only while nil meant "nobody has been asked": a
declared-None assignment *is* the one case with no language to name, so the two
language-shaped values become ordinary shell variables with a TODO apiece —
`FILE` for what the student submits, `RUN` for the command that runs it. That is
a scaffold the author completes, where `solution.py` + `python3` was one they had
to notice was wrong first.

Two defects fell out of touching it:

- **The per-language scaffolds never reached a browser.** `allTemplateInfos`
  and `shellTestScript` both defaulted `language:` to nil, and the scan endpoint
  omitted the argument — so the work that taught these templates to render
  `solution.R` / `Rscript` for R, and so on for Lua, Octave, C++ and Racket,
  was dead on arrival: every author of every language got the Python ones. Both
  defaults are gone, so a caller that forgets now fails to compile.
- **R's scaffold could not run.** It invoked `interpreterProbe.command`, which
  for R is `R` — the right probe for "is R installed", and a command that runs
  nothing: `R solution.R` reports the argument ignored and reads a REPL from
  stdin. The runner has always spawned `Rscript`. `LanguageDescriptor` carries
  `scriptRunCommand` now, and `RunCommandMatchesInvocationTests` (in WorkerTests,
  the one target that can see both Core's descriptor and Worker's invocation
  table) pins it against what the worker actually spawns.

The second is the general lesson, not an R quirk: a value in reach that is
*shaped* like the one you need is not the one you need. "Probe for it" and "run
it" are different questions, and the descriptor answered them with one field
because for five of six languages the answers coincide.

### An adjacent defect the work surfaced

`makeWorkerManifestJSON` builds a **fresh dict**, so any field it is not handed
is dropped by a rebuild. `languageDeclared` was never handed to it, and
`language` was not handed to it by the draft paths — so the create page's
`required` language select recorded the author's choice and the next suite
action (`replace-suite-files`, `clear-suite-files`, or the publish rebuild in
`saveNewAssignment`) erased it. Both fields are threaded now, and both halves
travel together: `language` alone cannot express "the author picked None", so
carrying only it would still turn a deliberate None back into an unanswered
question.

### Group 3 — keep the explicit default, and keep the comment

Ten lines where "none" is not an answerable value and failing is worse than
defaulting. Each states the default locally rather than inheriting it, which is
the property the Optional bought.

| Site | Why the default stays |
|---|---|
| `Worker/NotebookExtractor.swift:130` | Extraction has to write a file in *some* syntax; grading path |
| `Worker/RunnerDaemon+JobProcessing.swift:652` | The student-module hint must name the file the extractor actually wrote |
| `PersonalizationSubstitution.swift:55` | There is no literal without a syntax |
| ~~`TestScriptTemplates.swift`~~ | **Gone.** A language-less suite gets a *shell* scaffold — see below |
| `NotebookScaffoldHelpers.swift:165,167,174` | A notebook needs a kernelspec; nil already returns nil for upload-only |
| `PublishedAssignmentRoutes+NotebookTools.swift:87` | Scans an *arbitrary* notebook, not an assignment: the fallback chain is `?language=` → kernelspec → Python, and the distinction being drawn is between kernels we can read and ones we cannot |
| `SubmissionResultPresenter.swift:517` | Display; computes generated filenames, which only exist when families do, which requires a recorded language — unreachable with effect |
| `PublishedAssignmentRoutes+Suite.swift:133` | Same, for the author-facing suite view |
| `PatternFamilyApplication.swift:207` | The render standin on the declared-None path, inert by the guard above: nothing is rendered there, and the manifest records the declaration rather than this |

---

## Status at merge

Closed:

- `resolve(manifest:)` reads the declaration only; the sniff is gone from every
  read path.
- `rederive`, `isRNotebook`, `isRNotebookMetadata` deleted.
- All four creation doors declare; `BackfillDeclaredLanguage` covers the rest.
- The seventeen `language:` parameter defaults are gone and guarded.
- The browser runner boots only the declared language's substrate
  (`ensureReady`), rather than every kind present.

- The Group 1 authoring refusals and the Group 2 rewrite, with
  `UndeclaredLanguageRefusalTests` pinning both halves of each rule (what is
  refused *and* what must still be allowed).
- Manifest rebuilds preserve `language` + `languageDeclared`.

- The last content sniff on an authoring path is gone:
  `resolveAuthoringLanguage` returns the stored declaration. See "A declared
  language is not exclusive" below for why it was wrong rather than merely
  redundant.
- `RunnerLanguageGate` requires every language the suite actually needs, not
  just the declared one.

Deliberately open:

- Group 3 stays as it is. Those defaults are correct, not debt.

---

## A declared language is not exclusive

The declaration governs what Chickadee **generates**. It does not restrict what
the suite may hold, and never did.

| | `ScriptInterpreter` (RunnerCore) | `AssignmentLanguage` (Core) |
|---|---|---|
| scope | one script | one assignment |
| derived from | extension → shebang → content sniff | the author's declaration |
| cases | 13, incl. `sh` `bash` `zsh` `ruby` `perl` `node` `php` | 6 |
| answers | "how do I run this file?" | "what do generated artifacts render in?" |

`scriptInvocation(for:)` takes only a URL — no `AssignmentLanguage` parameter
exists and no caller passes one — and the runner stages *every* language's
`test_runtime.*` into every job workspace. `TestSuiteEntry` carries no language
field. No authoring surface refuses an off-language script; `KernelImportGuard`
switches on the script's own extension. A hand-written `.R` helper inside a
Python assignment runs under `Rscript`, and always has.

This is the original design — "test suites are shell scripts; the runner
executes them generically" — with per-language generation layered on top rather
than replacing it. **Shell is the substrate all six languages sit on**, which
is why "None" means "nothing is generated" and, in practice, "hand-written
scripts only".

### Two places that contradicted it

**Content voted on the declaration.** `resolveAuthoringLanguage` scanned the
authored scripts and let a non-Python extension outrank the stored language. It
ran on *every* suite save, including reorders, so authoring one `helper_test.R`
into a Python assignment re-rendered every generated script in R, **deleted** the
`.py` ones (the deletion diff reads `previous`), and wrote `.r` into the
manifest. It was asymmetric too — a `.py` helper could not flip an R assignment,
because Python was excluded by name — so the same act had opposite consequences
depending on which language you already had. It also went around the guard that
refuses a language change once generated scripts exist. Now it returns the
declaration; changing language is the dropdown's job and
`set_assignment_language`'s.

**The capability gate asked the wrong question.** It required exactly one token,
the declared language, so a `.R` helper in a Python assignment was claimable by
an R-less runner and died at `exit 127 / Rscript: not found` in front of a
student — this gate's own failure mode, in a shape it could not see.
`AssignmentLanguage.languagesRequiredToGrade(manifest:)` unions the declaration
with every language the suite's extensions imply. An empty set still fails open,
which is what keeps a plain `.sh` suite — and one written in an interpreter with
no capability token, like `.rb` or `.js` — claimable by anyone.

Both were the same root cause: using the declaration to answer a question about
*the suite's contents*, which only the contents can answer.

### Why "None" is not a `.shell` language

Tempting, because it would delete the Optional and collapse the remaining
fallbacks into the per-language capability tables. It does not work:
`languageByScriptExtension` folds every language's `scriptExtensions`, so a
`.shell` case claiming `["sh"]` would make every C++ assignment's generated `.sh`
wrappers derive as shell — `generatedScriptExtension: "sh"` is C++'s, and
`everyLanguageResolvesFromItsOwnGradedScript` carries an explicit C++ arm
asserting a bare `.sh` suite derives nil. Giving `.shell` no `scriptExtensions`
defuses that but breaks `update_solution`, which reads the same field to decide
which solution filenames are acceptable — one field, two questions, opposite
answers.

A *genuine* shell assignment language — students submit `solution.sh`, tests
source it and compare stdout, with a `test_runtime.sh` — is a defensible
separate feature. It would not replace "None", since a `.sh` harness that
compiles a student's C file is still an assignment with no generation language.
