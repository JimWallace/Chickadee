# Collaborative Class Assignments

Design note for a class of assignment Chickadee does not yet support: students
contribute individual artifacts (typically test cases) that are **accumulated**
into a class-wide result — "the class collectively reaches 85% coverage", "the
class collectively finds 12 of the 15 seeded bugs" — with marks flowing both
from the individual contribution and from the collective outcome.

Nothing here is locked. This records what the platform already does, what it
does not, and which of the open choices the existing machinery pushes toward.
It is written to be argued with before any of it is built.

## Summary

The request decomposes into three independent mechanisms. Two exist today.

| | mechanism | status |
|---|---|---|
| 1 | Grade a student's contributed test against seeded-buggy variants | **works today**, no code changes |
| 2 | A class-wide goal worth marks, frozen at the deadline, pushed to LEARN | **exists** (`Achievement` scope `.classWide`) |
| 3 | Compute that goal over the **union** of what the class produced | **missing** — this is the whole feature |

The gap is narrow and specific: every class goal today asks *how many students'
own best grade cleared a threshold*. Nothing aggregates over the union of
distinct items the class collectively covered.

## 1. Individual contribution — already expressible

Invert the usual roles. The instructor's test setup zip carries the reference
implementation plus N seeded-buggy variants and one driver shell script per
variant; the **student's submission is their test file**. Each suite entry runs
the student's test against one variant and maps exit 0/1 to found/not-found.
That is the existing script contract verbatim — the property that adding a
language means writing a shell script, not Swift.

Participation credit needs nothing new either: a `public`-tier entry asserting
"your test is well-formed and passes against the reference implementation",
plus `points` weighting and the partial-credit `score` footer.

Two platform constraints bind here:

- **The assignment must be worker-graded.** `BrowserRunnerRoutes.downloadTestSetup`
  streams the whole setup zip to the student's browser (minus grader-only
  files), so under browser grading the seeded bugs ship to the people hunting
  them. Worker grading is safe: `GET /api/v1/testsetups/:id/download` is
  course-scoped instructor-only (`Sources/APIServer/Routes/TestSetupRoutes.swift`).
  A collaborative assignment should refuse `gradingMode: browser` at save time
  rather than leak quietly.
- **The `student` tier does not exist.** `TestTier`
  (`Sources/RunnerCore/TestTier.swift`) has three cases — `pub`, `release`,
  `secret`. `TestTierValues.tiers` (`MCP/Tools/MCPSchema.swift`) still
  advertises a fourth, `"student"`, which `TestTier(rawValue:)` then rejects in
  `AuthorScriptTool`, while `SuiteRowHelpers` silently coerces an unrecognized
  tier to `.pub`. CLAUDE.md documents four tiers. This feature is presumably why
  that tier was imagined; it should be either implemented or struck from the
  schema and the docs before it is built on.

## 2. The class-wide goal — the framework is there

`Achievement` with `scope: .classWide` and a `points` reward already carries the
parts that are tedious to get right:

- `AchievementEvaluationService` sweeps every goal-bearing assignment on a
  5-minute timer and upserts one `APIAchievementResult` snapshot per (setup,
  achievement);
- snapshots **lock** at the deadline and then freeze;
- `ClassGoalBonus.swift` applies the bonus as uncapped extra credit at all three
  grade-of-record sites (submission page, BrightSpace push, grades CSV);
- `requeueFrozenClassGoalBonusPushes` re-pushes every student's grade to LEARN
  at the freeze, so early submitters are not permanently under-credited by
  whatever the class progress happened to be when their own run was graded.

That last one is the piece worth not rebuilding.

## 3. The gap: union, not count

`writeClassGoalSnapshots` computes exactly one thing:

```
studentsMeeting = bestByStudent.values.filter { $0 >= threshold }.count
progress        = min(1, (studentsMeeting / denominator) / classFraction)
```

and `isSweepEvaluableClassGoal` (`Core/AchievementEvaluation.swift`) deliberately
refuses any goal shape richer than a single `grade atLeast` condition, logging
and skipping rather than mis-grading. Every `AchievementSignal` reads a single
submission.

The two examples in the request need aggregates over the union of what the class
produced, and they cost very different amounts.

### Bug-set union — cheap, no new job shape

"Which seeded bugs has the class found" is a union over per-test pass sets, and
that data is already stored: the full `TestOutcomeCollection` JSON sits in
`result_collections.collection_json` for every submission. Nothing needs
re-running; this is a query, not a computation.

The one real constraint is where it runs. The sweep is deliberately blob-free
(the `#1160` note in `bestAssignmentGradeByStudent`), and unioning per-outcome
data across a term's submissions every 5 minutes would undo that. Accumulate
**incrementally at result-ingest** — `ResultRoutes` already calls
`awardClassBadgesFor100Percent` at exactly that point — and keep the sweep as
reconciliation.

### Coverage % — genuinely new

Coverage is not derivable from pass/fail. Two routes:

1. **Report per-student, union server-side.** Blocked by the output contract:
   `interpretScriptOutput` keeps only `shortResult`, `score` and `traceback` and
   discards the rest of the JSON footer. Adding a payload channel means changing
   RunnerCore — so the wasm build, `Tests/Fixtures/output-contract.json`, and
   both runners — plus storing a line-set per test per submission per attempt.
2. **Recompute over the accumulated corpus.** One job, run on a timer or at the
   deadline, that assembles every contributed test into a workspace, runs it
   against the reference under `coverage.py` / `covr`, and reports one number.

**Recommend (2).** It keeps coverage as a shell-script tool invocation, touches
no pinned contract, and the same mechanism serves any "run something over the
class corpus" goal — including the bug-set one, if computing beats unioning.

The precedent is closer than it looks. `ValidationVariant` +
`enqueueRunnerValidationSubmission` already create server-initiated synthetic
submissions, fan them to the runner, and collect verdicts into a side table.
`Core/Job.swift` does not care where the submission zip came from — the server
hands over a URL. What is missing is a corpus assembler, an aggregation
submission `kind`, and a results sink. Almost all of it is server-side.

## Limiting how much one student can contribute

There is **no machinery for this today**, in any form. Nothing counts, caps, or
rejects on submission volume. `requiredFiles` is advisory — it drives the upload
`accept` hint and the worker's notebook-extraction targeting, and nothing in the
intake path rejects a submission for having too many or too few files. Every
`maxAttempts` in the tree is a DB-lock or network retry policy. Availability is
gated by *when* (open/close, deadlines, slip days) and never by *how much*.

Three places a cap could live, meaning three different things:

### D. Notebook slots — bound the shape of the contribution, not its volume

The cheapest and most robust lever, and the one to reach for first: give the
starter notebook exactly K marked contribution slots and have the server keep
only what is in them.

This inverts the problem. You do not have to *prevent* a student adding cells —
you have to *ignore* the ones they added, which needs no UI enforcement at all
and cannot be bypassed by editing the file offline.

The seam already exists and is live on every submission path. `mergeNotebook`
(`Helpers/NotebookContentHelpers.swift`, called from `SubmissionRoutes` and all
three `BrowserResultRoutes` paths) already reassembles the submitted notebook
server-side: it keeps the student's non-test cells, re-imposes **all** of the
instructor's `# TEST:` cells, and adopts the instructor's kernelspec because —
in the words of its own comment — an in-browser editor cannot be trusted with
it. Slot extraction is the same operation with a different filter: keep the
student's cells that carry a slot marker, cap at K, drop the rest.

Two conventions are available for the marker, and the newer one is better:

- the **`# TEST:` first-line comment** (`isTestCell` / `isHiddenTestCell`) —
  established, but fragile in exactly the way that matters here: a student
  pressing return at the top of the cell silently unmarks it;
- **Chickadee-owned cell metadata** — `NotebookSubstitution` already writes
  `metadata.chickadee_personalized` to mark cells it owns, explicitly preserves
  any other cell metadata it finds, and uses the mark to avoid clobbering
  student edits on re-substitution. That proves Chickadee-namespaced cell
  metadata survives the full round-trip, and it is invisible to (and untouched
  by) ordinary editing.

Use the metadata form. A student who deletes the slot marker loses the slot,
which is the right failure: it is legible, it is their own doing, and the
starter can be reset.

What to do with a fourth test is then a policy choice with a graceful default —
keep the first K in document order and drop the rest, or keep all K+ for the
student's own individual mark and count only K toward the class aggregate (which
is B, below, arrived at from the other direction).

### The editor UI: a guardrail, never the guarantee

Worth stating plainly, because the notebook feels like the natural place to
enforce this and it is not:

- **Locking the scaffold cells is easy and worth doing.** nbformat carries
  `metadata.editable` and `metadata.deletable`, which JupyterLab honours;
  Chickadee sets neither today. Marking the instructions and the slot headers
  non-editable and non-deletable stops the ordinary accident — a student
  overwriting the prompt, or deleting a slot and not knowing how to get it back.
  This should be verified against the vendored 0.8.x build rather than assumed;
  the house rule that only a real kernel proves a kernel claim applies here too.
- **Disallowing new cells is not an nbformat capability.** Cell insertion is a
  notebook-level command, not a per-cell property, so no metadata suppresses it.
  Doing it would mean disabling the `notebook:insert-cell-*` commands in the
  command registry — either via `disabledExtensions` in `jupyter-lite.json`
  (already used for two plugins, but too blunt here: the insert commands live in
  the core notebook extension) or via a runtime prototype patch in the idiom of
  `Public/jl-cell-perf-patch.js`. It is a whack-a-mole surface — toolbar button,
  keyboard shortcuts, Edit menu, split-cell, paste-cell — and each new JupyterLab
  version can add another entry point.
- **Neither is enforcement, and the platform says so by design.** JupyterLite
  keeps the document in the student's own browser, and CLAUDE.md is explicit that
  notebook mode deliberately keeps the upload form beside the editor so a student
  can hand in an `.ipynb` edited offline. A collaborative assignment must be
  worker-graded (see above), which is exactly the mode where that upload path
  stays open. Any rule that only holds inside the editor does not hold.

So: lock the scaffold cells for the ergonomics, skip the cell-insertion patch,
and put the actual bound in the server-side slot extraction, where it holds
against every submission path at once.

### A. Intake cap — "submit at most K test cases"

Counting tests inside a student artifact is language-specific and heuristic;
`NotebookFunctionScanner` is Python-and-notebook-only and exists for authoring
stubs. It also fights the resubmit model, which is re-submittable by design
(attempt numbers, instructor retests, best-attempt folds) — a cap on submissions
and a cap on tests-per-submission are easy to conflate and only one of them is
meaningful.

**But the cheap version needs no Swift at all:** the instructor's driver script
counts the student's test functions and exits 1 with a message above K. Works in
every language, today. If the goal is only "don't dump 200 generated tests on
the grader", that is the answer and this section ends here.

### B. Credit cap at aggregation — "at most K union items are attributed to any one student"

This is what actually implements "no one student can do it all on their own",
and it does not stop a keen student from testing as much as they like for their
own mark. It is a field on the class goal, and it comes nearly free with the
union design, which already has to record *who* first covered each item to be
auditable at all.

Its trap is the crux of the whole feature. If A's tests cover items 1–10 and the
cap is 3, are items 4–10 *uncovered*? Saying yes tells the class it has not
found bugs it demonstrably found. Saying no means the cap does not constrain the
class number, which is what was asked for. These are different pedagogies and
the choice has to be made explicitly, not defaulted into:

- **capped credit** — the cap bounds the *individual* mark; the class number
  stays honest;
- **capped coverage** — the cap bounds the *class* number; one student cannot
  complete the goal alone.

### C. Participation breadth — the simpler lever, recommended default

Most of the intent is reachable without per-student cap arithmetic at all, by
ANDing two conditions on the goal:

1. union coverage ≥ threshold — the collective outcome;
2. ≥ `classFraction` of the roster contributed at least one credited item — the
   anti-solo-hero condition.

Condition 2 reuses the existing `classFraction` semantics nearly unchanged, and
it is monotone, order-independent, explainable to a student in one sentence, and
needs no attribution ranking. One student finding everything then fails the goal
on breadth rather than on a contested per-item cap.

This does require relaxing `isSweepEvaluableClassGoal` to admit a second
condition — but that guard exists precisely to reject shapes the sweep cannot
evaluate, so extending it alongside the evaluator is the intended move, not a
workaround.

**Recommendation: ship D for the shape of a contribution and C for its breadth.**
D bounds what one student can hand in without any UI enforcement to bypass; C
stops a solo hero completing the class goal. Keep A-in-a-shell-script for crude
volume control, and treat B as the stronger lever only if C proves insufficient
in a real offering.

## Semantics that must be decided either way

- **Attribution.** Attribute an item to the first submission that covered it.
  `APIClassAchievement` is the existing precedent for a first-to-X row, and
  first-finder attribution is what makes the individual half auditable.
- **Monotonicity.** The class number must never go down. It drives a visible
  progress bar and freezes into a LEARN push; a number that retreats because
  someone resubmitted is both alarming and, once frozen, wrong. Once an item is
  covered and attributed, it stays.
- **Determinism.** The sweep must produce the same number from the same data.
  Any ranking rule that lets a later submission change which of an earlier
  student's items counted (e.g. "credit the K rarest") breaks this — another
  reason to prefer breadth (C) over ranking (B).
- **Multiple attempts.** `bestAssignmentGradeByStudent` folds to each student's
  max. A union over *all* attempts is a farming vector — submit twenty narrow
  tests. A union over each student's best attempt is defensible. Pick
  explicitly; the fold is not obvious from the existing code.
- **Denominator.** `classGoalProgress` divides by the enrolled roster. A union
  goal has no roster denominator — it is covered/total items. `classFraction`
  reinterprets cleanly as "target fraction of the item set", but that reuse
  should be deliberate, and `APIAchievementResult`'s
  `studentsMeeting`/`denominator` field names would then lie.
- **Retention.** A materialized class corpus of student-authored tests is a
  second copy of student personal information. `SubmissionRetentionService` /
  `deleteCourse` would have to reach it, and the FIPPA/TL55 clock applies the
  same way.

## What this is not

Contributed tests becoming part of the suite that **other students are graded
against** is a different and much larger feature, and this design deliberately
excludes it. It would break the property that a submission's grade is a pure
function of (submission, test setup, seed): a student's mark would move when a
classmate submits, retests would not reproduce, and the versioning and
validation machinery all assume a fixed suite. Keeping grading deterministic and
putting the collective part entirely in the bonus is what makes the rest of this
tractable.

## Slice plan (individually mergeable)

1. **Resolve the `student` tier.** Implement it or strike it from
   `TestTierValues` and CLAUDE.md. Small, independent, and unblocks honest
   authoring of contributed-test suites.
2. **Refuse `gradingMode: browser` for collaborative assignments** at save time,
   with the leak as the stated reason.
3. **Slot extraction in `mergeNotebook`.** K marked contribution slots in the
   starter notebook, kept by Chickadee-owned cell metadata, everything outside
   them dropped server-side. Plus `editable`/`deletable` on the scaffold cells
   for ergonomics. Independent of the aggregate work and useful on its own.
4. **Per-outcome accumulation at result-ingest.** A table keyed by (setup, item,
   first-covering submission, user), written where `awardClassBadgesFor100Percent`
   is called. No goal semantics yet — just the durable union, with the sweep as
   reconciliation. Independently useful for instructor diagnostics.
5. **Extend `isSweepEvaluableClassGoal` and the evaluator** to admit a union
   condition and a breadth condition ANDed, keeping the skip-and-log behaviour
   for shapes it still cannot evaluate.
6. **Goal authoring + display**: the new condition shapes in the achievements
   editor, the MCP surface, and the student progress bar.
7. **Corpus aggregation run** (coverage only): assembler, aggregation submission
   kind, results sink, reusing the `ValidationVariant` fan-out shape.
8. **Per-student contribution cap (B)**, only if a real offering shows breadth
   (C) is not enough.

Slices 1–6 deliver the bug-set goal end to end. Coverage needs 7.

## Test plan (sketch)

- Pure-function tests for the union fold and the breadth predicate, without a
  database, mirroring how `classGoalProgress` is tested today.
- Monotonicity: replaying a submission stream in any order yields the same final
  number, and the number never decreases mid-stream.
- Freeze behaviour: a union goal that completes after the deadline does not move
  a frozen snapshot, and the LEARN re-push fires exactly once.
- Roster scoping: staff test submissions and dropped students contribute
  nothing, matching the numerator guard already in the sweep (audit A7).
- A skip-and-log test for a hand-authored goal shape the evaluator cannot read.
