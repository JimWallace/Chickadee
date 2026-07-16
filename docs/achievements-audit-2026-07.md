# Achievements: deployment-readiness audit + Labs 6–9 case study (2026-07)

Status: point-in-time audit ahead of the HLTH 230 Labs 6–9 rollout
(July 8/15/22 opens). Companion to `docs/achievements-unification.md`
(the design plan-of-record). Findings reference code as of v0.4.609.

Two questions, answered in order:

1. **Audit** — is the achievements subsystem polished enough to deploy on
   the next set of labs?
2. **Case study** — design meaningful, content-integrated achievements for
   HLTH 230 Labs 6–9 and prove they are creatable through the existing
   UI + MCP authoring surfaces (and name what is not).

**Verdict up front:** the composable model, the unified editor, and the two
authoring surfaces are in good shape (genuine web/MCP parity, one shared
validator). The evaluation layer is not caught up to what the authoring
layer lets you write, and two award paths are dead on browser-graded
assignments — which all four labs are. The case-study sets below were
successfully authored via MCP and are live on the (preview) labs, but they
had to be *designed around* four known bugs. Fix priorities are at the end.

---

## Part 1 — Audit findings

Three parallel audits (evaluation path, authoring surfaces, student-facing
display), cross-verified. Ranked; file:line references are v0.4.609.

> **Status update (same PR):** the P0s and P1s below are now **fixed** in this
> branch — A1 (+A14 mixed-signal badges, + save-time ref/id validation), A2,
> A3, A4 (save-time restriction + sweep skip-and-log), A5, A6, A7, A9 (docs),
> A10, and A19. Still open, deliberately: A8 (rounded-percent 100), A11–A13
> and A15–A18 (lifecycle/robustness items — revocation on retest, deadline
> unfreeze, manifest version check, dashboard display of authored badges,
> orphan-row FKs, sweep perf). Each fixed finding below is tagged FIXED.

### P0 — fix before the labs open

**A1 (FIXED). `testPass` conditions never match real runner outcomes as documented.**
`AchievementCondition.isSatisfied` compares `outcome.testName == target.ref`
(`Sources/Core/AchievementEvaluation.swift:50-53`), and both authoring
surfaces document `testRef` as the *script filename* (editor placeholder
`secrettest_x.py`, `assignment-edit.leaf:437-438`; MCP schema "the test
filename that must pass"). But RunnerCore stamps `testName` as the **display
name, else the extension-stripped stem** — never the filename
(`Sources/RunnerCore/SuiteExecution.swift:123-129`). A badge authored per
the documented contract can never fire, on either grading path. The
hint/display maps solved this exact ambiguity with filename+stem dual keys
(`SubmissionResultPresenter.swift:487-515`); the achievement matcher didn't.
`AchievementBadgeTests.swift:47-56` masks the bug by hand-building outcomes
whose `testName` is a full filename — a shape the runner never produces.
*Fix:* match ref against filename, stem, and display name (reuse the dual-key
approach); add author-time validation that the ref resolves against the
suite. Note generated pattern-family entries take the **case label** as
display name (`PatternFamilyRenderer.swift:216`), and case labels can
collide across families (Lab 8 has "single reading" in three families) —
ref resolution should prefer the filename.

**A2 (FIXED). Browser-graded assignments never award records or Pathfinder.**
Class records (`firstToSolve`/`fastest`/`shortest`) are awarded only in the
worker report handler (`ResultRoutes.swift:106-127`);
`BrowserResultRoutes.submitBrowserResult` never calls
`awardClassBadgesFor100Percent`. Pathfinder (`firstToSubmit`) is awarded
only in the zip-upload form handler (`WebRoutes+Submission.swift:155-175`)
— never on the notebook paths. **Every HLTH 230 lab is browser-graded**, so
all record-scope achievements are silently dead there (except when the
v0.4.56 worker backstop happens to regrade one — arbitrary and unfair).

**A3 (FIXED). Web suite editor script add/delete wipes authored achievements.**
`updateManifestAddingScript` / `updateManifestRemovingScript`
(`ManifestFileHelpers.swift:93-105, 139-151`) rebuild the manifest via
`makeWorkerManifestJSON` without forwarding `achievements`,
`disabledBuiltInAwardIDs`, or `builtInAchievementsSeeded`, which default to
empty/false (`:165-167`) — exactly the failure mode the comment at
`:211-214` warns about. Reached live from the edit page (Remove script,
upload script). The MCP equivalents (`author_script`/`delete_suite_item` →
`applySuiteEdit`) preserve them. Workflow consequence: curate achievements,
then touch one script in the web editor → **all achievements silently reset
to built-in defaults**.

### P1 — correctness, fix soon

**A4 (FIXED). The class-goal sweep evaluates only "first grade condition, atLeast".**
`evaluateClassGoalAchievements` reduces every goal to `best grade >= first
.grade condition` (`AchievementEvaluationService.swift:98-99` via
`gradeThresholdFraction`, `Core/AchievementEvaluation.swift:116-118`).
`match: any`, `atMost`/`equals`, multi-condition, and non-grade conditions
(attempts, testPass) are accepted by both authoring surfaces for classWide
goals and then silently ignored; a goal with *no* grade condition becomes
"100% required". This mis-computes **bonus points** (which reach the grades
CSV and BrightSpace), not just display. Record-scope `conditions` are
likewise never consulted at award time (`ClassAchievements.swift:36-55`).
*Fix:* either evaluate the full condition list in the sweep or reject
unsupported shapes at save time.

**A5 (FIXED). Clearing built-ins doesn't stop them being awarded.** Removing *all*
per-submission badges (or all records) — including `update_achievements`
with `[]`, advertised as "clear every achievement" — falls back to the
registry at evaluation: `manifestPerSubmission` returns nil for an empty
filtered list and `classRecordsForAward` does the same
(`BuiltInAchievements.swift:151-155, 178-185`), ignoring
`builtInAchievementsSeeded`. "A removed built-in stays removed" is only
true in the editor's GET view. (A curated list that keeps ≥1 badge and ≥1
record behaves correctly — the case-study sets do.)

**A6 (FIXED). Custom-ID class records award invisibly; rethemes don't display.**
The award path writes manifest-authored record IDs
(`BuiltInAchievements.classRecordsForAward`), but all three display sites
resolve via the **registry only** (`AchievementBadge.forClassAchievement`,
`WebContextTypes.swift:250-257`) — an unknown ID renders nothing, and a
kept built-in ID renders the registry's name/detail, not the instructor's
rename. A custom record is a permanently invisible DB row.

**A7 (FIXED). Class-goal numerator counts staff and unenrolled users.**
`bestAssignmentGradeByStudent` filters only `kind == .student`
(`AchievementEvaluationService.swift:139-147`) — staff test submissions and
dropped students inflate `studentsMeeting`, while the denominator counts
only enrolled students + pre-enrollments (`CourseRosterCounts.swift:39-63`).
The record path fixed exactly this in v0.4.127 (`ClassAchievements.swift:29-31`);
the sweep has no such guard. Unearned bonus points can reach BrightSpace/CSV.

**A8. "100%" is a rounded integer percent.** `gradePercent(from:)` rounds
(`TierFilter.swift:142-145`), so 99.5% ≥ "100" for records, Ace, and the
sweep numerator (`APIResult.swift:105-111` rounds before the `/100` at
`AchievementEvaluationService.swift:156`). Low impact on 4–8-point labs;
real on large suites.

**A9 (FIXED). `shortest` record dimension is mislabeled.** Evaluated as **fewest
attempts** (`ClassAchievements.swift:47-51`), matching the built-in
Minimalist's student-facing copy — but documented as "shortest solution" in
Core (`Achievement.swift:326-335`) and implied by the MCP schema. Rename the
case (or fix the docs) before an agent authors against the contract.

### P2 — robustness / lifecycle

- **A10 (FIXED). Achievements editor destructive empty-state:** a failed initial
  GET renders an empty table (`achievements-editor.js:305-308`), and the
  next save PUTs that emptiness wholesale. No error banner, no write guard.
- **A11. Manifest last-writer-wins race** between `PUT /achievements` and
  `PUT /suite` (no version check in `mutateManifest`,
  `SuiteEditHelpers.swift:322-337`) — concurrent staff edits silently lose
  rows.
- **A12. No revocation/recompute:** a retest that dethrones a record holder
  never updates `APIClassAchievement`; a retest-all with a new
  `firstToSolve` awards whichever regrade lands first, not the earliest
  solver. Deadline lock is one-way — extending a due date never unfreezes a
  locked goal snapshot (`AchievementEvaluationService.swift:92-109`).
- **A13. Numerator/denominator source drift:** the sweep uses
  latest-worker-preferred results while every grade-of-record surface uses
  best-across-all-results — a worker regrade below a browser 100% removes a
  student from the goal numerator while their recorded grade stays 100%.
- **A14. Mixed dynamic+testPass badges are unearnable under `match: all`:**
  the two evaluation sites are disjoint — `forSubmission` has no outcomes
  (`WebContextTypes.swift:238-246`), the authorable path has no
  attempt/time signals (`AchievementBadgeEvaluation.swift:30`) — despite
  the model advertising free composition.
- **A15. Authored badges missing from the dashboard:** grade/testPass
  badges are evaluated only on the submission page; dashboard and
  per-student rows show only per-submission + record badges
  (`WebRoutes+IndexRows.swift:104-173`) — an earned badge "vanishes" on the
  dashboard. Also inconsistent grade inputs: authored badges see the
  bonus-inflated grade, built-ins see the raw grade
  (`WebRoutes+Submission.swift:322-345` vs `SubmissionResultPresenter.swift:150-155`).
- **A16. Boot double-fire of the sweep** (detached run + immediate loop
  iteration under one lease, `PeriodicSweepMonitor.swift:102-122`,
  contradicting `APIAchievementResult`'s `@unchecked Sendable`
  justification); record award TOCTOU is last-write-wins
  (`ClassAchievements.swift:59-105`); goals with no due date are rescanned
  forever; the sweep JSON-decodes every manifest deployment-wide every
  5 minutes; BrightSpace bonus lookup is a per-student N+1
  (`BrightSpaceGradeSelection.swift:106`).
- **A17. Validation gaps (both surfaces, one shared validator):** no id
  uniqueness (duplicates collapse in the sweep's dict), no testRef
  existence check, no points cap or name/detail length caps,
  `recordDimension` silently defaults to `firstToSolve`. Round-trips strip
  `sectionID`, `icon`, custom `reward.label`, grade `target`s, and
  record-scope conditions (`AchievementsEditingService.swift:39-192`).
- **A18. Dead model surface:** `sectionID` is consumed by no display path;
  `TargetKind.suiteItem`/`.section` grade targets are ignored by
  `isSatisfied` (`Core/AchievementEvaluation.swift:39-40`); dead
  scope/reward combos (classWide+badge, individual+points) decode but never
  evaluate. `equals` on `executionTimeMs` is a Double-equality footgun.
- **A19 (FIXED). "+1 pts" pluralization** (`SubmissionResultPresenter.swift:404`).

### Privacy and tier interaction (clean, with one deliberate caveat)

- No cross-student identity leak found: every `APIClassAchievement` read is
  scoped to the viewer/holder; class goals expose only aggregate counts;
  MCP's student-data wall covers both achievement tables. Records are
  anonymized *by omission* — nobody can see a record is taken, which also
  blunts their competitive fun (see recommendations).
- A `testPass` badge on a **secret or release** test is a deliberate 1-bit
  oracle: badge present ⇔ hidden test passed, on every attempt, bypassing
  tier redaction (`AchievementBadgeEvaluation.swift:7-9,30` — intentional,
  pinned by test). Fine as a design tool; the editor should warn authors
  they're creating that signal.

### What's genuinely solid

- One shared authoring validator → real web/MCP parity; identical
  round-trip shape confirmed live against v0.4.609.
- Achievements edits correctly do **not** close/revalidate/regrade
  (display-only), consistently on both surfaces and documented on both.
- Browser-graded attempt reconciliation (`reconcileBrowserCollection`)
  makes Ace/attempt-based badges trustworthy on the browser path.
- Division-by-zero guards everywhere checked; fraction↔percent conversions
  consistent; dark-mode tokens for badges/goals all resolve; no student
  sees another's identity.

### Test-coverage gaps (the ones that matter)

No end-to-end `testPass` badge test through RunnerCore-produced outcome
names (would have caught A1); no browser-path record/Pathfinder award test
(A2); no test that web script add/delete preserves achievements (A3 — the
existing `suiteRebuildPreservesAchievementsAndToggles` tests the inner
function with explicit args, not the wrappers); no sweep test for
multi-condition/`match:any`/non-grade class goals (A4); no award-time test
for cleared built-ins (A5); no display test for custom-ID records (A6);
`equals` comparator untested anywhere; legacy-projection pinning covers 3
of 8 kinds; no regrade-interaction tests at all.

---

## Part 2 — Case study: custom achievements for HLTH 230 Labs 6–9

### The labs, as authored today

All four labs are **browser-graded** (Pyodide), in `preview` visibility,
grouped under the "Labs" course section. Before this exercise all four
carried the eight uncurated built-in defaults (Ace, Rally, Tenacious,
Swift, Pathfinder, Trailblazer, Fastest, Minimalist).

| Lab | ID | Content | Suite shape |
|-----|----|---------|-------------|
| 6 | `VTKF2H` | Food-log nutrition analysis: `copyToDictionary`, `loadFoodLog` (CSV totals), `findDeficiencies`, `findExcesses` | 4 scripts + 3 pattern families, 3 sections; 1 release test |
| 7 | `ZGty66` | Search & complexity: benchmark timings table, Big-O of linear/binary/`hasDuplicates` | 4 public scripts, 2 sections, 60 s limit (imports re-run student benchmarks) |
| 8 | `7kg2Aw` | Descriptive statistics on `exercise.csv`: count/min/max/mean/median, `countByGroup` | 5 pattern families + 1 release integration test, 3 sections |
| 9 | `Ze1JGH` | Capstone: NHANES hypertension classifier — `summarize`, `select_features`, `strongest_predictor`, secret accuracy ≥ 0.70 gate | 2 public + 1 release + 1 secret script; personalized cohorts. **No due date set** — fix before open (also: goals with no due date never freeze, A16) |

### Design principles

- **Tie every award to the lab's learning objective** — the badge name
  should teach the concept back.
- **Mix attainable / aspirational / collaborative:** each lab gets an
  "everyone should earn this" content badge, a stretch badge, a class-wide
  goal with a small bonus, and one record.
- **Remove awards that are wrong for browser grading.** `executionTimeMs`
  on a browser-graded lab measures the *student's laptop*, not their code —
  Swift and the Fastest record are a hardware lottery. On Lab 7
  specifically, importing the notebook re-runs the n=1,000,000 benchmark
  loops, so the 2 s Swift default was outright unearnable.
- **Drop Pathfinder** (first to submit *anything*) — it rewards racing an
  empty notebook to the server at open time. (It also doesn't award on
  browser-graded labs — A2.)

### The applied sets

Applied live via MCP `update_achievements` on 2026-07-05 and verified by
round-trip; labs are still in preview, so nothing is student-visible yet.
Re-running `update_achievements` with any other list is the undo.

**Lab 6 — "Daily Values" (food-log analysis)**

| Achievement | Scope | Trigger |
|---|---|---|
| Balanced Diet | individual | all 4 `findDeficiencies`/`findExcesses` case tests pass |
| Meal Prepped | individual | 100% on attempt 1 (Ace retheme) |
| Second Helping | individual | grade jump ≥ 50 (Rally retheme) |
| Tenacious | individual | 100% after ≥ 5 attempts |
| Community Kitchen | classWide, +1 pt | 75% of class at 100% |
| Trailblazer | record | first to 100% |

**Lab 7 — "Growth Rates" (search & Big-O)**

| Achievement | Scope | Trigger |
|---|---|---|
| Growth Mindset | individual | all three Big-O answers correct |
| Empiricist | individual | benchmark-table test passes |
| Constant Time | individual | 100% on attempt 1 — "O(1): one attempt" |
| Iterative Refinement | individual | 100% after ≥ 5 attempts |
| Replication Crisis, Averted | classWide, +1 pt | 80% of class at 100% |
| Trailblazer | record | first to 100% |

**Lab 8 — "Vital Signs" (descriptive statistics)**

| Achievement | Scope | Trigger |
|---|---|---|
| Full Panel | individual | a case from each of maximum/mean/median/countByGroup passes |
| Clinical Significance | individual | release integration test passes (reproduces published pulse values) |
| Outlier | individual | 100% on attempt 1 |
| Significant Improvement | individual | grade jump ≥ 50 |
| Sample Size Matters | individual | 100% after ≥ 5 attempts |
| Well-Powered Study | classWide, +1 pt | 85% of class at 100% |
| Trailblazer | record | first to 100% |

**Lab 9 — "Predict It" (hypertension classifier capstone)**

| Achievement | Scope | Trigger |
|---|---|---|
| Epidemiologist | individual | `strongest_predictor` release test passes |
| Clinical Grade | individual | secret accuracy test passes — a deliberate "your model clears the bar" signal (see tier caveat) |
| First, Do No Harm | individual | 100% on attempt 1 |
| Breakthrough | individual | grade jump ≥ 50 |
| Hyperparameter Grind | individual | 100% after ≥ 5 attempts |
| Population Health | classWide, +1 pt | 70% of class at 100% (100% implies the accuracy gate) |
| Trailblazer | record | first to 100% |

### How the designs were shaped by the bugs (the honest part)

Every set above works **only because it was designed around Part 1**:

1. **`testRef`s are display names, not filenames** (A1 workaround). E.g.
   Lab 7 uses `"Big-O: linear search"`, Lab 8's Full Panel picks case
   labels that are *unique across families* ("largest comes first", "four
   readings", "five unsorted readings", "three activities") because labels
   like "single reading" collide across three families. This is fragile —
   renaming a test's display name or relabeling a case silently kills the
   badge. Fix A1 and re-author refs as filenames.
2. **Class goals are single `grade ≥ 100` conditions** (A4). The natural
   authoring — "N% of the class passes the benchmark test" — is accepted
   and then silently mis-evaluated, so all four goals gate on grade only.
3. **Records keep the stock `trailblazer` id/name** (A6): a rethemed
   "First Diagnosis" would be awarded under a custom ID and never render.
   And until A2 is fixed, **no record will award on these labs at all** —
   the row is kept so it lights up when the browser path is wired.
4. **Each set keeps ≥ 1 individual badge and ≥ 1 record**, so the A5
   registry fallback can't resurrect the removed Swift/Pathfinder/Fastest/
   Minimalist.
5. **No badge mixes attempts/time/jump signals with `testPass`** (A14).
6. Known cosmetic gap: the content badges (testPass-based) will show on
   the submission page but not the dashboard row (A15).

Tier caveat, made deliberately: **Clinical Grade** (Lab 9) and **Clinical
Significance** (Lab 8) surface pass/fail of a secret/release test as a
badge — a motivating 1-bit reveal that bypasses tier hiding. That is the
intended design here (the accuracy gate is otherwise invisible feedback),
but it is a choice to reconfirm before opening Lab 9.

---

## Part 3 — Creatability verdict + recommendations

### Can an instructor create these easily today?

- **MCP: yes, mechanically.** One `get_achievements` + one
  `update_achievements` per lab; the whole four-lab case study was applied
  agent-side in four calls with clean round-trips. The schema is clear
  about scopes and per-scope params. But the tool's contract points authors
  at two traps: "testRef = filename" (never matches, A1) and "send [] to
  clear" (doesn't suppress built-ins at award time, A5), and it accepts
  classWide condition shapes the sweep ignores (A4).
- **Web editor: yes, same shapes** (same validator, condition builder
  covers all five signals) — but the testRef is a free-text field with a
  misleading filename placeholder, achievements are lost if you then
  add/remove a script on the edit page (A3), and a transient load failure
  can nuke the list on the next save (A10).
- **Not expressible on either surface** (model supports, authoring
  doesn't): per-section/per-suite-item grade conditions (the natural "Full
  Panel = Descriptive Statistics section at 100%" — worked around with
  testPass lists), `sectionID` display grouping, custom reward labels/
  icons, points rewards on individual badges. **Not expressible at all:**
  cross-assignment achievements ("Ace on all four labs", streaks) — the
  model is strictly per-assignment; that's the natural next step for the
  gamification roadmap.

### Fix order before/after the labs open

**Before Lab 6 opens (Jul 8):**
1. A1 — testPass ref matching (filename+stem+displayName) + author-time ref
   validation. Unblocks the flagship content badges.
2. A2 — award records/Pathfinder on the browser paths. Otherwise accept
   that records are dormant this term (the applied sets tolerate this).
3. A3 — forward achievement fields through the two web manifest-rebuild
   helpers (small, mechanical, prevents instructor data loss).
4. Set Lab 9's due date.

**Soon after:**
5. A4 (sweep honors authored conditions, or save-time rejection), A5
   (curated-empty suppresses registry fallback), A7 (numerator roster
   guard), A6 (registry-or-manifest display resolution).
6. The P2 lifecycle items (revocation on retest, deadline-lock unfreeze,
   editor empty-state guard, manifest version check).

**Design follow-ups worth a look:**
- Show unearned individual achievements (name + detail) on the submission
  page — students can't chase a badge they can't see; the model and copy
  already exist.
- Surface record holders (opt-in, first-name-or-anonymous) so records
  actually compete.
- A "browser-graded" authoring warning on `executionTimeMs` conditions,
  and a tier-leak note on testPass refs to release/secret tests.
- Cross-assignment/meta achievements as the next gamification increment.
