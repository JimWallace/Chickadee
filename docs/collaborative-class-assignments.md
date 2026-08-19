# Collaborative Class Assignments

Design note for a class of assignment Chickadee does not yet support: students
contribute individual artifacts (typically test cases) that are **accumulated**
into a class-wide result — "the class collectively reaches 85% coverage", "the
class collectively finds 12 of the 15 seeded bugs" — with marks flowing both
from the individual contribution and from the collective outcome.

This was written as a design note, to be argued with before any of it was built.
Slices 0-7 of the plan at the bottom have since shipped, so most of it now
describes behaviour rather than intent — see **Status** below for which is
which. The reasoning is kept as written, because the arguments are what the
choices rest on.

## Status

| slice | what | state |
|---|---|---|
| 0 | Strike the phantom `student` tier (`MCPTierProse` + coverage guard) | shipped |
| 1 | Refuse browser grading for grader-only files | struck — `graderOnlyFiles` already refuses at all three authoring doors |
| 2 | Contribution slots (`chickadee_slot` cell metadata, bounded in `mergeNotebook`) | shipped |
| 3 | Per-item class coverage accumulation (`class_item_coverage`), gated to contribution assignments | shipped |
| 4 | The instructor coverage view ("Bug coverage" on the submissions page) | shipped |
| 5 | The `itemsCovered` union signal and the breadth predicate | shipped |
| 6 | Authoring and display (editor, student status line, MCP surface) | shipped |
| 7 | Freeze and LEARN re-push | shipped — rides the existing paths; the snapshot now stores the coverage it froze at |
| 8 | Corpus aggregation run for coverage % | **deliberately not started** — see Phase 4 |

Two things a reader should not go looking for. **There is still no per-student
contribution cap by attribution ranking** (option B): slots bound the shape of a
contribution and breadth bounds the solo hero, and ranking is what would break
determinism. And **coverage % is not implemented** — the union is a set of
covered items, not a coverage number; a real offering should run a bug hunt
before the corpus machinery is built.

One thing left to the instructor's hand for now: **a slot is declared by
`chickadee_slot` cell metadata**, which is hand-edited in the notebook JSON.
There is no authoring affordance for it yet.

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

- **The seeded bugs are `graderOnly` support files, and that already forces
  worker grading.** `BrowserRunnerRoutes.downloadTestSetup` streams the whole
  setup zip into the student's kernel filesystem, so under browser grading the
  variants would ship to the people hunting them. Chickadee already has the
  mechanism and the refusal for exactly this: a manifest's `graderOnlyFiles`
  names files withheld from every student-facing path, and
  `gradingMode: browser` combined with a non-empty `graderOnlyFiles` is refused
  at all three authoring doors — the zip upload
  (`TestSetupRoutes.swift`), MCP `set_grading_mode`, and MCP `author_script` —
  with the streaming filter and `manifestWithGraderOnlyFilesStripped` as
  backstops for setups predating the rule. So an instructor marks the variant
  implementations `graderOnly` and browser grading becomes unavailable by
  construction. Nothing to build; the constraint is an authoring instruction.
  Worker grading is safe on the other side too: `GET /api/v1/testsetups/:id/download`
  is course-scoped instructor-only.
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

## How this reads in the UI

The good news is how little new surface this needs. Three of the four screens
already exist and take the feature as data; only one view is genuinely new, and
it assembles entirely from the component vocabulary.

### Instructor: authoring the goal

**No template or JS changes.** The achievements editor
(`#achievement-editor-template` in `_assignment-edit-body.leaf`) is already the
composable shape this needs: a scope dropdown, a list of typed conditions
combined with all/any, a "Class share ≥ (%)" field and a "Bonus points" field,
both already gated to `classWide`.

The condition-signal dropdown renders from `achievementSignalOptions`, which
comes from `AchievementSignalPresentation.all` — `AchievementSignal.allCases`
through an **exhaustive switch**. Adding a signal is therefore a compile error
until it is given a label and a unit, and the dropdown then renders itself. A
new signal costs one enum case and one switch arm; the instructor UI updates for
free.

What the instructor authors for a bug hunt:

| field | value |
|---|---|
| Awarded to | The class together |
| Earned when | *Items covered by the class* — at least — `12` — in section `Seeded bugs` |
| Class share ≥ (%) | `60` |
| Bonus points | `5` |

The item **set** needs no new targeting concept: `AchievementTarget.kind` already
has `.section`, so "the tests in the *Seeded bugs* section" is expressible today.
Putting the variant tests in a suite section is something the instructor does in
the suite editor anyway.

`classFraction` ("Class share") keeps its exact sentence — the share of the class
that must satisfy the per-student part — and only the per-student part differs by
goal: for a grade goal it is "cleared the grade threshold", for a union goal it is
"contributed at least one credited item". Same field, same label, evaluator
branches.

### Student: the submission page

The "Class goals" block in `submission.leaf` already renders name, reward,
a `<progress>` bar, and a status line, and it is the right shape unchanged. One
word in it is wrong for a union goal:

```
#(goal.studentsMeeting) / #(goal.denominator) students
```

`ClassGoalView` gains a `progressNoun` (`"students"` / `"bugs found"`), the
template interpolates it, and the presenter fills it from the goal. **No new
CSS** — which matters, because `PAGE_STYLE_BASELINE` in `check-styles.sh` is a
shrink-only ratchet on total page `<style>` lines, so a new page-local rule fails
CI by design. Reusing `.class-goal*` verbatim is not just tidy, it is the only
mechanically legal option short of a catalog entry.

Rendered, a union goal reads:

```
Seeded Bug Hunt                                    +5 pts
[============================------------]
60% of the way · 9 / 15 bugs found · 22 / 34 contributed
```

### Student: the notebook

Nothing to build. The slots are markdown and code cells in the starter notebook —
**content, not chrome** — so they are authored in the editor like any other
scaffold. `editable: false` / `deletable: false` on the prompt cells is a
metadata change to the starter, not a UI feature.

### Instructor: the one genuinely new view

"Which bugs has the class found, and who found each one" has no home today. It
belongs on the per-assignment instructor page that already carries submission
analytics (`assignment-submissions.leaf`) rather than a new tab.

It assembles from existing vocabulary with **zero new classes**: a
`.page-section` holding a `.results-table`, with `.chip-ok` / `.chip-err` for the
found/not-found state.

| Bug | Status | First found by | When |
|---|---|---|---|
| `variant_03` | ✅ found | s.chen | Mar 4, 09:12 |
| `variant_07` | ✅ found | j.okafor | Mar 4, 14:40 |
| `variant_11` | — not found | — | — |

This is also the view that makes the aggregate auditable, which is why the
per-outcome accumulation slice is worth landing before the goal semantics: it is
independently useful to an instructor watching a lab in progress.

### The UI rules this has to clear

- `scripts/check-styles.sh` (page-style ratchet, class resolution, design
  tokens, no native `alert()`), and `check-ui-vocabulary.sh` if any global class
  is added — which the plan above avoids entirely.
- The `ui-review` agent is **required** on any change touching
  `Resources/Views/`, `Public/styles.css`, or a page-wiring `Public/*.js`. Green
  guards are necessary, not sufficient; every style regression so far has been
  mechanically legal.
- Copy stays at house length: chips and labels are two-or-three-word noun
  phrases, a `title` is one phrase, and anything longer goes in `docs/` with the
  UI linking to it.

## Implementation plan

Nine slices, each individually mergeable and each leaving the tree shippable.
Slices 0–2 are cleanups that stand on their own merit; 3–7 build the bug-hunt
assignment end to end; 8 is coverage, which is a bigger step and deliberately
last. Sizes are relative, not estimates.

### Phase 0 — clear the ground (independent of everything else)

**0. Resolve the `student` tier.** *Small.* **Done.** Struck rather than
implemented: the suite is instructor-authored and a student's contribution is
submission content, not a suite entry, so the feature that would have wanted the
tier does not. The prose is now derived from `TestTier.allCases` (`MCPTierProse`)
rather than typed in thirteen places, guarded by `MCPTierCoverageTests` against
both a phantom value and a truncated list.
*Proven by:* reintroducing each defect and watching the guard fail. Four of the
thirteen sites were ones the initial search missed — the guard found them.

**1. ~~Refuse `gradingMode: browser` for contribution assignments.~~ Already
built — struck.** This slice proposed a special case for a mechanism that
already exists in general form. `graderOnlyFiles` + `gradingMode: browser` is
refused at all three authoring doors, filtered at the download, and blanked out
of the served manifest; the refusal is covered by
`uploadRejectsGraderOnlyFilesWithBrowserGrading`,
`BrowserManifestGraderOnlyStripTests`, and the two MCP tool suites. Marking the
variant implementations `graderOnly` is therefore an authoring instruction, not
a code change.

The lesson is worth keeping: the plan reached for a new narrow guard where a
general one was already in place, and only reading the download path closely
found it. Check for the general mechanism before adding the specific one.

### Phase 1 — bound the contribution (useful on its own)

**2. Slot markers and slot extraction.** *Medium.* **Done.** The core of the
feature, and it turned out to fit entirely inside `mergeNotebook`'s existing
signature — the instructor notebook is already in hand at that call site, so the
slot count derives there with no call-site changes and no new plumbing.
- A Chickadee-owned cell metadata key (`metadata.chickadee_slot`) following the
  `chickadee_personalized` precedent in `NotebookSubstitution`, which already
  proves the round-trip and already preserves foreign cell metadata.
- `mergeNotebook` gains the filter: keep the student's slot-marked cells in
  document order, cap at the slot count, drop everything else, then re-impose the
  instructor's cells as it does today. It runs on all four submission paths
  already, so one change covers the upload form and all three browser routes.
- The slot count is **derived from the starter notebook**, never stored
  separately — no manifest field to drift from the notebook it describes. This is
  the same "derive, do not tabulate" rule `AuthoringLanguageFacts` follows.
- `editable: false` / `deletable: false` on the scaffold cells.

The one open authoring question: how an instructor *marks* a slot. Typing a
marker comment that the server converts to metadata on notebook save keeps the
gesture inside ordinary notebook editing and needs no editor surface; a
JupyterLite toolbar action would be nicer and costs a runtime patch. Recommend
the marker comment for v1 and revisit only if instructors ask. **Still open** —
the extraction half is built and the authoring gesture is not, so slots are
currently declared by hand-editing cell metadata.

**One sharp edge, recorded rather than hidden.** A helper the student writes
OUTSIDE a slot is dropped with everything else, and their test then fails at
grading against a name that is no longer defined. Keeping unmarked cells would
reopen the bypass this bound exists to close (fifty tests in one unmarked cell),
so the documented behaviour is what shipped — but it is the thing most likely to
confuse a real student, and worth revisiting if an offering shows them tripping
over it.
*Proven by:* extraction tests over a student notebook with cells added, removed,
reordered and unmarked; plus a test that an offline-edited upload with twenty
cells still grades exactly the slot contents.

### Phase 2 — accumulate (useful on its own)

**3. Per-item coverage accumulation at result-ingest.** *Medium.* **Done.**
`APIClassItemCoverage`, one row per (assignment, item) attributed to the
submission that covered it first, written at both result-ingest paths. No goal
semantics yet — just the durable, attributed union.

Three properties are enforced rather than intended. **First-finder wins is a
schema constraint**, not a code convention: the unique index on
(test_setup_id, item) is what makes the union monotone and idempotent under
re-tests, replayed reports and concurrent submissions, so the class number can
never go down. **Coverage is ungated by grade** — it sits outside the
`grade == 100` gate the class badges use, because a student who covers one item
and nothing else has still contributed it. **It is roster-scoped**, for the
reason audit A7 gives: an unscoped numerator once carried unearned bonus points
to the LMS.

Scoped to CONTRIBUTION assignments, which was a correction rather than the
original shape. The first version recorded for every assignment, on the
reasoning that the union is generically useful. One slice later that proved
wrong in a way only the consumer could reveal: rows exist for every passing test
on every lab forever, and the instructor view then has no cheap way to tell a
bug hunt from an ordinary assignment — so it would need a second signal, or it
would render a coverage section on every instructor page. Gating the write on
`declaredSlotCount > 0` means the mere EXISTENCE of coverage rows answers that
question.

Wired at BOTH ingest paths deliberately. The class records were once awarded
only in the worker handler, so browser-graded assignments never awarded any
until audit A2 caught it — a half-wired accumulator is worse than none, because
its number reads as the whole class when it is only the half graded on one
substrate.
Incremental at ingest rather than folded in the sweep, because the sweep is
deliberately blob-free (the `#1160` note) and unioning per-outcome data across a
term every five minutes would undo that.
*Proven by:* replaying a submission stream in several orders and asserting one
final state; asserting the number never decreases mid-stream.

**4. The instructor coverage view.** *Small.* The table described above on
`assignment-submissions.leaf`. Ships on slice 3 alone and makes the aggregate
auditable before anything grades on it.
*Proven by:* a render test plus the `ui-review` agent.

### Phase 3 — grade on it

**5. The union signal and the breadth predicate.** *Medium.* A new
`AchievementSignal` case reading the accumulated coverage against an
`AchievementTarget` of kind `.section`, plus the breadth half of the evaluator.
Extend `isSweepEvaluableClassGoal` to admit the new shape while keeping its
skip-and-log behaviour for everything it still cannot read — that guard is the
reason a hand-authored manifest cannot silently mis-grade, and it must stay
closed.
*Proven by:* pure-function tests for the fold and the predicate with no database,
mirroring how `classGoalProgress` is tested today; plus a skip-and-log test for a
shape the evaluator cannot read.

**6. Authoring and display.** *Small.* Falls out of slice 5 almost entirely: the
signal dropdown renders itself from the exhaustive switch, and the student block
needs one interpolated noun. What remains is the MCP surface — `get_server_info`
and the achievement tools — which must describe the new shape without hand-typing
a list, per the `MCPLanguageProse` rule that cost two fixes to learn.
*Proven by:* the existing MCP coverage tests, extended to the new signal.

**7. Freeze and push.** *Small.* Confirm the union goal rides the existing
deadline freeze and the one-shot LEARN re-push (`requeueFrozenClassGoalBonusPushes`)
rather than needing its own. This is mostly a test slice, and it is the one that
protects the grade of record.
*Proven by:* a union goal completing after the deadline does not move a frozen
snapshot, and the re-push fires exactly once.

### Phase 4 — coverage (the bigger step)

**8. Corpus aggregation run.** *Large.* Assemble every contributed slot into one
workspace, run it against the reference under the language's coverage tool, and
record one number. Reuses the `ValidationVariant` shape: a server-initiated
synthetic submission, fanned to the runner, verdict collected into a side table.
Needs a corpus assembler, an aggregation submission kind, a results sink, and a
retention story — a materialized corpus of student-authored tests is a second
copy of personal information and `deleteCourse` has to reach it.

Everything before this delivers the bug-hunt assignment. Do not start it until a
real offering has run one.

### What is deliberately not in the plan

- **A per-student contribution cap (option B).** Slot extraction bounds the
  contribution and breadth bounds the solo hero; a per-item attribution cap adds
  ranking, and ranking is what breaks determinism. Revisit only if a real
  offering shows the two cheaper levers are insufficient.
- **A cell-insertion patch in JupyterLite.** Slot extraction makes extra cells
  harmless, so the patch buys tidiness against a whack-a-mole surface that each
  JupyterLab release can extend.
- **Contributed tests grading other students.** Out of scope for the reasons
  above — it breaks grade reproducibility.

### Sequencing note

Slices 0–4 are all independently valuable and none of them grades anything, so
they can land while the semantics in 5–7 are still being argued. That ordering is
deliberate: it puts the auditable instructor view in front of a human *before*
any of this moves a mark.

## Cross-cutting checks

Each slice above names what proves it. Three checks span the whole feature and
belong wherever the last of their inputs lands:

- **Roster scoping.** Staff test submissions and dropped students contribute
  nothing to a union or a breadth count, matching the numerator guard already in
  the sweep (audit A7). That guard exists because unscoped numerators granted
  unearned bonus points all the way to the LMS.
- **Order independence.** The final state is the same however the submission
  stream is interleaved, and the class number never decreases mid-stream.
- **Grade of record.** The bonus reaches all three sites — submission page,
  BrightSpace push, grades CSV — through `earnedWithClassGoalBonus` rather than
  any site re-deriving it. The grades CSV once carried its own copy of the cap
  and that is how it drifted.
