# Assignment language: declared, not inferred

Where the multi-language transition stands as of v0.5.59 (#1330, #1331), what
the rule now is, and the fourteen call sites that are still answering a
different question.

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

## What is still open: the fourteen `?? .python` sites

These are **not** resolution fallbacks. Resolution has no fallback. They are
sites asking a different question:

> This operation needs a language, and the assignment declares none. Now what?

They divide into three groups, and the decision rule that separates them is:

**Fail loudly while authoring. Never fail while grading, rendering a page, or
extracting a student's submission.**

An author can fix a missing declaration in ten seconds and a refusal tells them
how. A student cannot fix it at all, and a refusal on their path turns an
instructor's omission into a failed submission.

### Group 1 — authoring: a refusal is the right answer

The justification written at these sites ("refusing would be circular — a
pattern family is frequently the FIRST thing authored, and generating its
scripts is how the suite acquires a graded script") was written **under
inference**, when nil genuinely meant "nothing has named a language yet". It is
dissolved by declaration: creation always declares, so nil at these sites means
the author chose *None*, and authoring a Python pattern family on an assignment
whose author said it has no language is the exact silent-wrong-answer shape this
arc removed.

| Site | Currently |
|---|---|
| `PatternFamilyApplication+Inputs.swift:232` | Generates `.py` scripts on a declared-none assignment |
| `GlobalInputsService.swift:232` | Evaluates `=` expressions with `python3` |
| `SectionInputsService.swift:179` | Same, for section variables |

Note the seam for the two inputs services: they run at **evaluation** time,
which is on the acting seed and can be reached by a student page load. The
refusal belongs at the **save** that stores the expression, not here. Leave the
evaluator's stated default alone and add the guard where the expression is
authored.

### Group 2 — sites that should stop naming a language at all

These do not need a fallback; they need a rewrite that never asks the question.

| Site | Fix |
|---|---|
| `UpdateSolutionTool.swift:171` | Only asks whether the language is `.uploadOnly`. `if case .uploadOnly = language?.editorSupport` answers it with no default and no behaviour change |

### Group 3 — keep the explicit default, and keep the comment

Nine sites where "none" is not an answerable value and failing is worse than
defaulting. Each already states the default locally rather than inheriting it,
which is the property the Optional bought.

| Site | Why the default stays |
|---|---|
| `Worker/NotebookExtractor.swift:130` | Extraction has to write a file in *some* syntax; grading path |
| `Worker/RunnerDaemon+JobProcessing.swift:652` | The student-module hint must name the file the extractor actually wrote |
| `PersonalizationSubstitution.swift:55` | There is no literal without a syntax |
| `TestScriptTemplates.swift:147` | Scaffold text; nil output byte-for-byte matches the previous Python |
| `NotebookScaffoldHelpers.swift:165,167,174` | A notebook needs a kernelspec; nil already returns nil for upload-only |
| `PublishedAssignmentRoutes+NotebookTools.swift:87` | Scans an *arbitrary* notebook, not an assignment: the fallback chain is `?language=` → kernelspec → Python, and the distinction being drawn is between kernels we can read and ones we cannot |
| `SubmissionResultPresenter.swift:517` | Display; computes generated filenames, which only exist when families do, which requires a recorded language — unreachable with effect |
| `PublishedAssignmentRoutes+Suite.swift:133` | Same, for the author-facing suite view |

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

Deliberately open:

- The Group 1 refusals above. They are authoring-behaviour changes on a branch
  that auto-deploys, and they want their own change with their own tests.
- Group 3 stays as it is. Those defaults are correct, not debt.
