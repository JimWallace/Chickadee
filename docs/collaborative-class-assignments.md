# Collaborative Class Assignments

In a contribution assignment, each student contributes an individual artifact,
usually a test case. Chickadee accumulates these artifacts into a class-wide
result, for example "the class collectively reaches 85% coverage" or "the class
collectively finds 12 of the 15 seeded bugs". Marks come from the individual
contribution and from the collective outcome.

This document describes the design as built. It keeps the reasons for each
choice, because the choices rest on them.

## Status

The feature is built. Contribution slots, per-item class coverage, the
instructor coverage view, the `itemsCovered` union signal with its breadth
predicate, the corpus run for coverage percent, and the authoring and display
surfaces all ship. A union goal uses the existing deadline freeze and LEARN
re-push. Not built: an authoring affordance for slots. An instructor declares a
slot by hand-editing `chickadee_slot` cell metadata in the notebook JSON.

Some code comments cite a phase number from the old implementation plan. This
table maps it to the current section.

| phase | what it built | section that describes it now |
|---|---|---|
| Phase 4 | The corpus aggregation run for coverage percent (`class_coverage_runs`, the `classAggregate` submission) | "The corpus run" |

## Class goals in force

This section states the class-goal rules as built. The sections after it give
the mechanisms and the reasons.

**A class goal counts one of three things.** An `Achievement` with scope
`.classWide` reads one of three arithmetics:

- **Students meeting a grade.** How many students' best whole-assignment grade
  clears a threshold, over the enrolled roster. This was the only arithmetic
  before contribution assignments.
- **The union of items** (`AchievementSignal.itemsCovered`). The count of
  DISTINCT items in the `class_item_coverage` table, for example "the class has
  found 12 of the 15 seeded bugs". It can be scoped to one suite section, so a
  bug hunt counts its variants and not the well-formedness gate beside them.
- **The corpus percent** (`AchievementSignal.classCoverage`). The newest
  COMPLETED `class_coverage_runs` row: one `kind == .classAggregate`
  submission, graded once, whose grade fraction is the number. A union of
  per-item rows cannot give this number. It scopes nothing, because the run
  gives one number for the assignment (see "The corpus run").

**`isSweepEvaluableClassGoal` admits exactly four shapes:** no conditions, a
single `grade atLeast`, a single `itemsCovered atLeast`, or a single
`classCoverage atLeast`. Every other shape is refused at save time and skipped
with a log by the sweep. That guard is the reason a hand-authored manifest
cannot silently mis-grade a bonus (audit A4). Admit a new shape only together
with the evaluator that reads it; the arity has never moved.

**A union or corpus goal grades on the SMALLER of two halves.** The halves are
coverage (the item count or the corpus percent) and breadth (at least
`classFraction` of the roster contributed one covered item, or one cell to the
corpus). Breadth is why there is no per-student contribution cap: one student
who finds everything reaches full coverage and then fails on breadth. Crediting
each student only their K rarest items would also bound that student, but it
breaks determinism, because a later submission can change which of an earlier
student's items counted.

**The two halves scope differently, on purpose.**

- **Coverage counts every row**, including a row found by a student who has
  since dropped. The item was covered, and the number must never retreat,
  because it freezes into a LEARN push.
- **Breadth counts only currently-enrolled students**, because it is a fraction
  of the CURRENT roster (audit A7).
- A corpus goal has the same split. The run's number is what it measured, and
  its stored contributor list is intersected with the current roster.

`achievement_results` stores `items_covered` / `items_required` (and
`coverage_percent` / `coverage_required`). It does not recompute them, so a
frozen row can say what coverage produced the bonus in each student's grade of
record.

## Summary

The feature has three independent mechanisms.

| | mechanism | where |
|---|---|---|
| 1 | Grade a student's contributed test against seeded-buggy variants | the existing script contract; no special code |
| 2 | A class-wide goal worth marks, frozen at the deadline, pushed to LEARN | `Achievement` scope `.classWide` |
| 3 | Compute that goal over the **union** of what the class produced | `class_item_coverage` and the corpus run |

A grade goal asks how many students' own best grade cleared a threshold. A
union goal asks how many distinct items the class covered together.

## 1. Individual contribution

The usual roles are inverted. The instructor's test setup zip carries the
reference implementation, N seeded-buggy variants, and one driver shell script
per variant. The **student's submission is their test file**. Each suite entry
runs the student's test against one variant and maps exit 0/1 to
found/not-found. That is the existing script contract verbatim — the property
that adding a language means writing a shell script, not Swift.

Participation credit needs nothing new either: a `public`-tier entry asserting
"your test is well-formed and passes against the reference implementation",
plus `points` weighting and the partial-credit `score` footer.

Two platform constraints apply:

- **The seeded bugs are `graderOnly` support files, and that forces worker
  grading.** `BrowserRunnerRoutes.downloadTestSetup` streams the whole setup zip
  into the student's kernel filesystem, so under browser grading the variants
  would ship to the people hunting them. A manifest's `graderOnlyFiles` names
  files withheld from every student-facing path, and `gradingMode: browser`
  combined with a non-empty `graderOnlyFiles` is refused at all three authoring
  doors — the zip upload (`TestSetupRoutes.swift`), MCP `set_grading_mode`, and
  MCP `author_script`. The streaming filter and the browser manifest endpoint,
  which serves only the runner contract (`browserRunnerManifestJSON`), are
  backstops for setups that predate the rule. The refusal is covered by
  `uploadRejectsGraderOnlyFilesWithBrowserGrading`,
  `BrowserManifestGraderOnlyStripTests`, and the two MCP tool suites. So an
  instructor marks the variant implementations `graderOnly`, and browser grading
  becomes unavailable by construction. This is an authoring instruction, not a
  code change. Worker grading is safe on the other side too:
  `GET /api/v1/testsetups/:id/download` is course-scoped instructor-only. Check
  for a general mechanism like this one before you add a specific guard.
- **There is no `student` tier.** `TestTier`
  (`Sources/RunnerCore/TestTier.swift`) has three cases — `pub`, `release`,
  `secret`. The suite is instructor-authored, and a student's contribution is
  submission content, not a suite entry. So this feature does not want a tier.
  The MCP tier prose is derived from `TestTier.allCases` (`MCPTierProse`), not
  typed by hand. `MCPTierCoverageTests` fails on a phantom tier value and on a
  truncated list.

## 2. The class-wide goal

`Achievement` with `scope: .classWide` and a `points` reward carries the parts
that are tedious to get right:

- `AchievementEvaluationService` sweeps every goal-bearing assignment on a
  5-minute timer and upserts one `APIAchievementResult` snapshot per (setup,
  achievement);
- snapshots **lock** at the deadline and then freeze;
- `ClassGoalBonus.swift` applies the bonus as uncapped extra credit at all three
  grade-of-record sites (submission page, BrightSpace push, grades CSV); on an
  activity that runs per lab group, a grade goal is counted per lab and each
  student earns their own lab's bonus (`docs/lab-groups.md`, slice 5a);
- `requeueFrozenClassGoalBonusPushes` re-pushes every student's grade to LEARN
  at the freeze, so early submitters are not permanently under-credited by
  whatever the class progress happened to be when their own run was graded.

A union goal and a corpus goal use the same deadline freeze and the same
one-shot LEARN re-push. They have no separate path. A union goal that completes
after the deadline does not move a frozen snapshot, and the re-push fires
exactly once. The snapshot stores the coverage it froze at.

## 3. Class goals over the union

For a grade goal, `writeClassGoalSnapshots` computes this:

```
studentsMeeting = bestByStudent.values.filter { $0 >= threshold }.count
progress        = min(1, (studentsMeeting / denominator) / classFraction)
```

A union goal or a corpus goal needs an aggregate over what the class produced.
The two examples cost different amounts, so they use different mechanisms.

### Bug-set union: per-item coverage at result-ingest

"Which seeded bugs has the class found" is a union over per-test pass sets. The
full `TestOutcomeCollection` JSON is already stored in
`result_collections.collection_json` for every submission, so nothing re-runs.
A bug-set union is a query over stored rows, not a computation.

The union accumulates **incrementally at result-ingest**, not in the sweep. The
sweep is deliberately blob-free (the `#1160` note in
`bestAssignmentGradeByStudent`). Unioning per-outcome data across a term's
submissions every 5 minutes would undo that.

`APIClassItemCoverage` (`class_item_coverage`) holds one row per (assignment,
item). The row is attributed to the submission that covered the item first.
`recordClassItemCoverage` (`Services/ClassItemCoverage.swift`) writes it. These
properties are enforced, not only intended:

- **First-finder wins is a schema constraint.** The unique index on
  (test_setup_id, item) makes the union monotone and idempotent under re-tests,
  replayed reports and concurrent submissions. The class number can never go
  down.
- **Coverage is not gated by grade.** It sits outside the `grade == 100` gate
  that the class badges use. A student who covers one item and nothing else has
  still contributed that item.
- **Coverage is roster-scoped.** Only a submission from a student in the setup's
  own course counts, for the reason audit A7 gives: an unscoped numerator once
  carried unearned bonus points to the LMS.
- **Coverage is gated to contribution assignments.** The write happens only when
  `declaredSlotCount > 0`. So the EXISTENCE of coverage rows tells the
  instructor view that an assignment is a contribution assignment, and the view
  needs no second signal. Not chosen: recording for every assignment, because it
  stores a row per passing test per assignment forever, and the view then cannot
  cheaply tell a bug hunt from an ordinary lab.
- **Both ingest paths write it**, the worker report and the browser result
  routes. The class records were once awarded only in the worker handler, so
  browser-graded assignments never awarded any until audit A2 caught it. A
  half-wired accumulator is worse than none, because its number reads as the
  whole class when it is only the half graded on one substrate.
- On an activity that runs per lab group, the items count for the lab of the
  session the student submitted in (`docs/lab-groups.md`, slice 5b).

### Coverage percent: the corpus run

Coverage is not derivable from pass/fail. Chickadee recomputes it over the
accumulated corpus: one job assembles every contributed test into a workspace,
runs it against the reference, and reports one number. The coverage tool runs
as a shell-script tool invocation, so no pinned contract changes. The same
mechanism serves any "run something over the class corpus" goal.

Not chosen: each student reports coverage and the server unions it, because
`interpretScriptOutput` keeps only `shortResult`, `score` and `traceback` and
discards the rest of the JSON footer. A payload channel would change RunnerCore
— the wasm build, `Tests/Fixtures/output-contract.json`, and both runners — and
would store a line-set per test per submission per attempt.

### The corpus run

**The corpus is a submission owned by nobody.** `APISubmission.Kind` has
`classAggregate`: the assembled notebook is written to the submissions directory
and enqueued through the same `materializeValidationGrading` path a
`kind == .validation` run uses, with `userID` nil. This follows the
`ValidationVariant` + `enqueueRunnerValidationSubmission` precedent:
`Core/Job.swift` does not care where the submission zip came from. Every
listing, aggregate and grade selection filters on `student`, so the corpus is
invisible to all of them. The nil owner means it cannot be attributed to a
student even by a path that forgets to filter. The claim seam puts it LAST,
behind student work, tournament matches and validation: nobody is watching it
land, and a deadline spike is exactly when a student's job must not queue behind
it.

**The coverage number is the run's own grade.** The script contract does not
change. The suite runs over the corpus and the collection's
`earnedPoints / totalPoints` is the coverage — the points, not `gradePercent`,
which rounds to a whole percent. A bug hunt's per-variant drivers answer "how
many of the seeded bugs does the class's combined test file find"; a
coverage-tool entry answers "what fraction of the reference do they exercise".
Both are the existing contract read at the class level. There is no runner code,
no manifest field and no footer key for this.

**It is opt-in behind the goal that reads it.** `scheduleClassCorpusRun` does
nothing unless the manifest carries a `classCoverage` class goal. A corpus run
is a whole extra grading job per contribution burst, and a number nobody reads
is runner time taken from students. Gating on the goal also means the run exists
exactly where something renders it.

**Debounced to one run in flight.** Every result on a contribution assignment
reaches the scheduler, so without the debounce a deadline spike would queue one
corpus run per submission, each grading a corpus the next one supersedes. The
in-flight run is the `class_coverage_runs` row with no `completed_at`; the next
contribution after it lands starts the next run. Readers take the newest
COMPLETED row, so a queued re-run never blanks a number that freezes into a
grade push. The result is one row in `class_coverage_runs`, not a side table.

**A failed build completes the run with no number.** A corpus that could not
compile says nothing about what the class covers, and recording it as zero would
drop a live progress bar to nothing. The run still completes, so the debounce
releases.

**The two halves scope the way the union's do.** COVERAGE is what the corpus
measured, including a contribution from a student who has since left; BREADTH
counts only currently-enrolled contributors, because it is a fraction of the
CURRENT roster (audit A7). Progress is the smaller, so one student writing an
exhaustive suite in their own slots reaches full coverage and then fails on
breadth — the same anti-solo-hero property, for the same reason, which is why
this shape needs no contribution cap either.

**The goal shape is a single `classCoverage atLeast P` with NO target.** The
corpus run produces one number for the assignment, so a `.section` target would
name a share of a reference nothing measured.

**Three things the corpus deliberately does not do.**

- **It does not call `mergeNotebook`.** That function applies the per-student
  slot bound, so passing N students' contributions through it would truncate the
  corpus to one student's worth of cells. The cells it assembles were bounded
  once each, at submission time, by that same function.
- **It refuses a personalized assignment.** A corpus is one artifact graded
  once, and a per-student assignment has no single set of inputs to grade it
  against. Grading it under one student's seed would report a number about
  nobody.
- **It resolves no name collisions.** Two contributors who both call their test
  `test_1` shadow each other under the language's own rules, and the class's
  coverage is quietly short by one test. Chickadee cannot fix this without
  rewriting student source per language, which is the thing the shell-script
  contract exists to avoid. The mitigation is the scaffold: a slot prompt that
  asks for a distinctive name. In the first real offering, measure first whether
  the assembled corpus grades as one artifact at all.

**Determinism is a writer option, not a property of the assembly.** Contributors
are ordered by user id — ordering by submission time would reshuffle the corpus
whenever anybody resubmitted — and the notebook is serialized with
`.sortedKeys`. Without that option two assemblies of an unchanged corpus differ
byte for byte, because `JSONSerialization` emits object keys in parse order. A
test asserts that the same inputs give the same bytes.

## Limiting how much one student can contribute

Chickadee bounds the **shape** of a contribution with notebook slots. Nothing
counts, caps, or rejects on submission volume. `requiredFiles` is advisory — it
drives the upload `accept` hint and the worker's notebook-extraction targeting,
and nothing in the intake path rejects a submission for having too many or too
few files. Every `maxAttempts` in the tree is a DB-lock or network retry policy.
Availability is gated by *when* (open/close, deadlines, slip days) and never by
*how much*.

There are four levers. D and C are in force. A is an instructor technique. B is
not built.

### D. Notebook slots — bound the shape of the contribution, not its volume

The starter notebook has exactly K marked contribution slots. The server keeps
only what is in them (`Utilities/NotebookContributionSlots.swift`).

The server does not *prevent* a student adding cells. It *ignores* the cells
they added. This needs no UI enforcement and an offline edit of the file cannot
bypass it.

`mergeNotebook` (`Helpers/NotebookContentHelpers.swift`, called from
`SubmissionRoutes` and all three `BrowserResultRoutes` paths) reassembles the
submitted notebook server-side on every submission path. It keeps the student's
non-test cells, re-imposes **all** of the instructor's `# TEST:` cells, and
adopts the instructor's kernelspec because an in-browser editor cannot be
trusted with it. On a contribution assignment it also keeps the student's
slot-marked cells in document order, caps them at the slot count, and drops
every other student cell. One change covers the upload form and all three
browser routes.

- **The marker is Chickadee-owned cell metadata**, `metadata.chickadee_slot`.
  Any non-empty value marks a slot. The value is a label for the author and for
  display; order is document order. This follows `NotebookSubstitution`, which
  writes `metadata.chickadee_personalized` to mark cells it owns, preserves any
  other cell metadata it finds, and uses the mark to avoid clobbering student
  edits on re-substitution. That proves Chickadee-namespaced cell metadata
  survives the full round-trip, and ordinary editing does not see or touch it.
  Not chosen: the `# TEST:` first-line comment (`isTestCell` /
  `isHiddenTestCell`), because a student pressing return at the top of the cell
  silently unmarks it.
- **A student who deletes the slot marker loses the slot.** This is the right
  failure: it is legible, it is their own doing, and the starter can be reset.
- **The slot count is derived from the starter notebook**, never stored
  separately. No manifest field can drift from the notebook it describes. This
  is the same "derive, do not tabulate" rule `AuthoringLanguageFacts` follows. A
  slot count of zero means an ordinary assignment, and no bound applies.
- **Extra student tests are dropped.** The first K slot cells in document order
  are kept.
- **A helper outside a slot is dropped too.** A helper the student writes
  OUTSIDE a slot is dropped with everything else, and their test then fails at
  grading against a name that is no longer defined. Keeping unmarked cells would
  reopen the bypass this bound exists to close (fifty tests in one unmarked
  cell). This is the behaviour most likely to confuse a real student. Revisit it
  if an offering shows students tripping over it.
- **Not built: a slot authoring affordance.** An instructor declares a slot by
  hand-editing the cell metadata in the notebook JSON.

### The editor UI: a guardrail, never the guarantee

The notebook feels like the natural place to enforce the bound. It is not.

- **Locking the scaffold cells is an ergonomic aid.** nbformat carries
  `metadata.editable` and `metadata.deletable`, which JupyterLab honours.
  Chickadee sets neither. An instructor can set both to `false` on the
  instructions and the slot headers in the starter. This stops the ordinary
  accident: a student overwrites the prompt, or deletes a slot and does not know
  how to get it back. Verify this against the vendored JupyterLite build before
  you rely on it; only a real kernel proves a kernel claim.
- **Disallowing new cells is not an nbformat capability.** Cell insertion is a
  notebook-level command, not a per-cell property, so no metadata suppresses it.
  Not chosen: a cell-insertion patch, because slot extraction makes extra cells
  harmless. The patch would mean disabling the `notebook:insert-cell-*`
  commands, through `disabledExtensions` in `jupyter-lite.json` (too blunt: the
  insert commands live in the core notebook extension) or through a runtime
  prototype patch in the idiom of `Public/jl-cell-perf-patch.js`. It is a
  whack-a-mole surface — toolbar button, keyboard shortcuts, Edit menu,
  split-cell, paste-cell — and each new JupyterLab version can add another entry
  point.
- **Neither is enforcement, by design.** JupyterLite keeps the document in the
  student's own browser, and notebook mode deliberately keeps the upload form
  beside the editor so a student can hand in an `.ipynb` edited offline. A
  collaborative assignment must be worker-graded (see above), which is exactly
  the mode where that upload path stays open. Any rule that only holds inside
  the editor does not hold.

The actual bound is the server-side slot extraction, which holds against every
submission path at once.

### A. Intake cap — "submit at most K test cases"

Chickadee has no intake cap. Counting tests inside a student artifact is
language-specific and heuristic; `NotebookFunctionScanner` is
Python-and-notebook-only and exists for authoring stubs. A cap also fights the
resubmit model, which is re-submittable by design (attempt numbers, instructor
retests, best-attempt folds). A cap on submissions and a cap on
tests-per-submission are easy to conflate, and only one of them is meaningful.

**The cheap version needs no Swift:** the instructor's driver script counts the
student's test functions and exits 1 with a message above K. This works in every
language. Use it when the goal is only "do not dump 200 generated tests on the
grader".

### B. Credit cap at aggregation — "at most K union items are attributed to any one student"

Not built. Slot extraction bounds the contribution and breadth bounds the solo
hero. A per-item attribution cap adds ranking, and ranking is what breaks
determinism. Revisit it only if a real offering shows that the two cheaper
levers are insufficient.

B would be a field on the class goal. The union already records who first
covered each item. B has one trap, and a revisit must decide it explicitly. If
A's tests cover items 1–10 and the cap is 3, are items 4–10 *uncovered*? Yes
tells the class it has not found bugs it demonstrably found. No means the cap
does not constrain the class number. These are different pedagogies:

- **capped credit** — the cap bounds the *individual* mark; the class number
  stays honest;
- **capped coverage** — the cap bounds the *class* number; one student cannot
  complete the goal alone.

### C. Participation breadth — the lever in force

A union or corpus goal ANDs two conditions:

1. union coverage ≥ threshold — the collective outcome;
2. ≥ `classFraction` of the roster contributed at least one credited item — the
   anti-solo-hero condition.

Condition 2 reuses the existing `classFraction` semantics nearly unchanged. It
is monotone, order-independent, explainable to a student in one sentence, and
needs no attribution ranking. One student finding everything fails the goal on
breadth rather than on a contested per-item cap.

`isSweepEvaluableClassGoal` admits these shapes alongside the evaluator that
reads them. That guard exists to reject shapes the sweep cannot evaluate, so it
stays closed for everything else.

## Semantics

- **Attribution.** An item is attributed to the first submission that covered
  it. `APIClassAchievement` is the precedent for a first-to-X row, and
  first-finder attribution is what makes the individual half auditable.
- **Monotonicity.** The class number never goes down. It drives a visible
  progress bar and freezes into a LEARN push; a number that retreats because
  someone resubmitted is both alarming and, once frozen, wrong. Once an item is
  covered and attributed, it stays.
- **Determinism.** The sweep produces the same number from the same data. A
  ranking rule that lets a later submission change which of an earlier
  student's items counted (for example "credit the K rarest") breaks this. That
  is why breadth (C) is in force and ranking (B) is not.
- **Multiple attempts.** `bestAssignmentGradeByStudent` folds a grade goal to
  each student's max. `recordClassItemCoverage` runs for each graded
  submission, so the union collects the items from every attempt. Slots bound
  each attempt, not the number of attempts.
- **Denominator.** A grade goal divides by the enrolled roster. A union goal's
  coverage half is covered items over required items (`items_covered` /
  `items_required`). Its `classFraction` keeps its roster meaning for the
  breadth half, so `studentsMeeting` / `denominator` count contributing students
  over the roster.
- **Retention.** A class corpus of student-authored tests is a second copy of
  student personal information. `deleteCourse` reaches `class_coverage_runs`
  and `class_item_coverage`. `SubmissionRetentionService` must reach them too;
  it does not reach them today. The FIPPA/TL55 clock applies the same way.

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

Three of the four screens are existing screens that take the feature as data.
One view is new, and it uses only the existing component vocabulary.

### Instructor: authoring the goal

The achievements editor (`#achievement-editor-template` in
`AssignmentEditBody`) has a scope dropdown, a list of typed conditions combined
with all/any, a "Class share ≥ (%)" field and a "Bonus points" field. The last
two are gated to `classWide`.

The condition-signal dropdown renders from `achievementSignalOptions`, which
comes from `AchievementSignalPresentation.all` — `AchievementSignal.allCases`
through an **exhaustive switch**. A new signal is therefore a compile error
until it is given a label and a unit, and the dropdown then renders itself. A
new signal costs one enum case and one switch arm.

What the instructor authors for a bug hunt:

| field | value |
|---|---|
| Awarded to | The class together |
| Earned when | *Items covered by the class* — at least — `12` — in section `Seeded bugs` |
| Class share ≥ (%) | `60` |
| Bonus points | `5` |

The item **set** needs no new targeting concept: `AchievementTarget.kind` has
`.section`, so "the tests in the *Seeded bugs* section" is expressible. The
instructor puts the variant tests in a suite section in the suite editor.

`classFraction` ("Class share") keeps its exact sentence — the share of the class
that must satisfy the per-student part. Only the per-student part differs by
goal: for a grade goal it is "cleared the grade threshold", for a union goal it
is "contributed at least one credited item". Same field, same label, evaluator
branches.

The MCP surface — `get_server_info` and the achievement tools — describes the
signals without a hand-typed list, per the `MCPLanguageProse` rule.

### Student: the submission page

The "Class goals" block in `SubmissionPage` renders name, reward, a
`<progress>` bar, and a status line. `ClassGoalView` carries two fields for a
union goal:

- `studentsLabel` names what `studentsMeeting` counts: "students" on a grade
  goal, "students contributing" on a union goal. One noun for both would invite
  "12 students have finished" on a bug hunt.
- `coverageSummary` gives the coverage half, for example "9 / 15 items found".
  It is nil on a grade goal. The bar reports the SMALLER of coverage and
  breadth, so a class that has met breadth needs to see the half that still
  holds the goal back.

The status line is built like this:

```
<progressPercent>% of the way · <studentsMeeting> / <denominator> <studentsLabel> · <coverageSummary>
```

**No new CSS.** `PAGE_STYLE_BASELINE` in `check-styles.sh` is a shrink-only
ratchet on total page `<style>` lines, so a new page-local rule fails CI by
design. Reusing `.class-goal*` verbatim is the only mechanically legal option
short of a catalog entry.

Rendered, a union goal reads:

```
Seeded Bug Hunt                                    +5 pts
[========================----------------]
60% of the way · 22 / 34 students contributing · 9 / 15 items found
```

### Student: the notebook

Nothing to build. The slots are markdown and code cells in the starter notebook —
**content, not chrome** — so they are authored in the editor like any other
scaffold. `editable: false` / `deletable: false` on the prompt cells is a
metadata change to the starter, not a UI feature.

### Instructor: the one genuinely new view

"Which bugs has the class found, and who found each one" is the "Class
coverage" section on the per-assignment instructor page that carries submission
analytics (`AssignmentSubmissionsPage`). It is not a new tab. It renders only
when the assignment has coverage rows.

It uses existing vocabulary with **zero new classes**: a `.page-section` with a
summary chip and a `.results-table`, with the existing status chips for the
found/not-found state.

| Item | Status | First found by | When |
|---|---|---|---|
| `variant_03` | found | s.chen | Mar 4, 09:12 |
| `variant_07` | found | j.okafor | Mar 4, 14:40 |
| `variant_11` | not yet found | — | — |

This view makes the aggregate auditable. It is useful on its own to an
instructor watching a lab in progress, before any goal grades on it.

### The UI rules this has to clear

- `scripts/check-styles.sh` (page-style ratchet, class resolution, design
  tokens, no native `alert()`), and `check-ui-vocabulary.sh` if any global class
  is added — which this design avoids entirely.
- The `ui-review` agent is **required** on any change touching
  `Sources/APIServer/Views/`, `Public/styles.css`, or a page-wiring `Public/*.js`. Green
  guards are necessary, not sufficient; every style regression so far has been
  mechanically legal.
- Copy stays at house length: chips and labels are two-or-three-word noun
  phrases, a `title` is one phrase, and anything longer goes in `docs/` with the
  UI linking to it.

## Cross-cutting checks

Three checks span the whole feature:

- **Roster scoping.** Staff test submissions and dropped students contribute
  nothing to a union or a breadth count, matching the numerator guard in the
  sweep (audit A7). That guard exists because unscoped numerators granted
  unearned bonus points all the way to the LMS.
- **Order independence.** The final state is the same however the submission
  stream is interleaved, and the class number never decreases mid-stream.
- **Grade of record.** The bonus reaches all three sites — submission page,
  BrightSpace push, grades CSV — through `earnedWithClassGoalBonus` rather than
  any site re-deriving it. The grades CSV once carried its own copy of the cap
  and that is how it drifted.
