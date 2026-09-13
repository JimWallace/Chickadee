# Class Activities

Design note and implementation record for a family of in-class activity types:
leaderboard challenges, "beat the instructor" bots, king of the hill,
round robins, elimination tournaments, tests-versus-implementations and
best-metric leaderboards. The collaborative bug hunt that shipped under
[collaborative-class-assignments.md](collaborative-class-assignments.md) is one
member of this family and does not change.

The plan is issue #1508. It is written so that an agent can pick it up cold:
read **Model** and **Compatibility rules** before touching code. Each slice is
one PR, done in order, and each must leave `main` green and every existing
assignment on the code path it runs today.

## Status

| slice | what | state |
|---|---|---|
| 0 | This design note | shipped |
| 1 | Leaderboard surface and raw metric: `metric` footer field, the `activity` block with `beatTheInstructor` and `bestMetric`, `leaderboard_entries` at ingest, `RecordDimension.highestMetric`, the leaderboard page, `set_activity` | shipped |
| 2 | Opponent primitive with `supportFile`: `CHICKADEE_OPPONENT_DIR` / `CHICKADEE_MATCH_SEED`, the `activity-match` runner capability, the browser-grading refusals | not started |
| 3 | `champion` opponent (king of the hill) | not started |
| 4 | `classmates` matrix, standings, the `standing` / `matchesWon` signals | not started |
| 5 | Elimination and Swiss brackets, `run_tournament` | not started |
| 6 | Asymmetric matrix (tests versus implementations) | not started |
| 7 | Synthetic class submission (coverage percent) | not started |
| 8 | Live-session controls (`openWindow`, countdown, auto-refresh) | not started |

Two things a reader should not go looking for after slice 1. **There is no
opponent in the workspace yet.** A `beatTheInstructor` assignment in slice 1 is
authored the way a bug hunt is: the instructor bundles the bot as a grader-only
support file and writes the match script by hand; the runner does not know it
is a match. Slice 2 is what makes the bot a first-class opponent. And **the
web create page has no activity control.** The kind is chosen on the edit page
(the "Class activity" select) or through MCP `set_activity`, either of which is
free until the first student submission. Creation-time choice is a follow-up.

## Design decisions (settled)

1. **An activity is an assignment, not a new content type.** Content items are
   ungraded. An activity needs grading, achievements, freeze and the LEARN push,
   and all of that hangs off an assignment. The manifest gains an optional
   `activity` block; `nil` means today's behaviour at every branch.
2. **Two orthogonal axes, hidden behind named kinds.** Internally an activity is
   an *opponent source* (what else is in the workspace when the script runs, and
   how many times it runs) plus a *class aggregation* (how the class's results
   combine). The instructor never sees the axes. They pick one **activity kind**
   and the kind fixes both axes and seeds the defaults.
3. **The kind is locked once a student submits.** Same rule as the language.
   There is no migration from an individual lab to a tournament under live
   submissions. The leaderboard's visibility is a display setting and may change
   at any time.
4. **Match detail is staff-only.** A match script can print the opponent's
   source into `longResult`. Students see score and pseudonymous handle only.
   Opponents are never named to students.
5. **Leaderboards are opt-in per assignment, default hidden.** Every existing
   assignment already carries seeded `record` achievements. A leaderboard that
   rendered on every assignment by default would change what students see today.
6. **One `TestOutcome` per suite entry, as today.** A match entry reports one
   aggregated outcome whose `score` is the win fraction. Per-match rows go to a
   `match_results` table (slice 4). `Tests/Fixtures/output-contract.json` only
   ever gains rows.
7. **Standings are materialised at ingest, not in the sweep.** The same pattern
   as `class_item_coverage`: the sweep is blob-free by design (#1160) and only
   reconciles.
8. **Brackets run on frozen entrants.** An elimination or Swiss tournament is
   started by an instructor action that snapshots each student's latest
   submission. Round robin and king of the hill are resubmission-tolerant.

## Model

### Activity kinds

| Kind | Opponent source | Aggregation | Seeds | Slice |
|---|---|---|---|---|
| `beatTheInstructor` | `supportFile` (a grader-only bot) | `leaderboard` | one `record` on `highestMetric` (slice 1); the match suite entry (slice 2) | 1, 2 |
| `bestMetric` | `none` | `leaderboard` on a raw metric | one `record` on `highestMetric` | 1 |
| `kingOfTheHill` | `champion` (the current best submission) | `leaderboard` | match entry, `record` champion | 3 |
| `roundRobin` | `classmates`, schedule `all` | `standings` | match entry, `record` winner, `standing` badges | 4 |
| `elimination` | `classmates`, schedule `bracket` or `swiss` | `standings` | match entry, `record` winner | 5 |
| `bugHunt` | `variants` (instructor's seeded variants) | `union` | already shipped, re-described only | — |
| `testsVersusImplementations` | `classmates`, asymmetric | `union` for testers, `standings` for implementers | match entry, contribution slots | 6 |

`ActivityKind` (`Sources/Core/ClassActivity.swift`) carries only the kinds that
work end to end. A kind the runner cannot execute is a silent misroute, not a
feature, so each arrives with the slice that makes it grade. The two axes are
not yet types of their own: `aggregatesToLeaderboard` is the one derived fact
slice 1 needs, and `ActivityOpponentSource` lands with slice 2.

### Manifest block (Core, `TestProperties.activity`)

```json
"activity": {
  "kind": "bestMetric",
  "leaderboardVisibility": "hidden"
}
```

Every field but `kind` decodes with a default. Later slices add
`trialsPerMatch`, `schedule` and `freezeAt` (nil meaning the assignment
deadline, resolved through `postDeadlineRevealDeadline` so the slip-day claim
window is honoured) as they are used, not before.

The block is **server-side only**. `runnerSanitized()` strips it, and that is
what protects a runner: an `ActivityKind` case a runner's build predates would
throw in the enum decoder and take the whole manifest with it. A match learns
what it needs from the job, never from an enum it may not know.

### The `metric` footer field

The stdout footer gains an optional `metric` beside `score`:

```json
{ "score": 1, "metric": 1234.5, "shortResult": "tour length 1234.5" }
```

`score` stays clamped to `0...1` and drives credit. `metric` is an unclamped
`Double` for **ranking** and nothing reads it for a grade. The two are
orthogonal to each other and to the exit code: a failing run may still report
the distance it reached, and a script that wants a failing run off the board
reports no metric on failure. A non-numeric `metric` is ignored. A script that
reports none has no ranking position rather than a default one, which is the
one way `metric` is not like `score`.

`RunnerCore.interpretScriptOutput` parses it, `TestOutcome.metric` carries it
(absent from the JSON when nil, so an ordinary record's bytes are unchanged),
the wasm bridge marshals it, and the contract fixture pins all three cases.
Both runners share the one implementation, so there is no JS change.

**Higher is better.** `RecordDimension.highestMetric` and the leaderboard both
rank descending. A script measuring something where lower wins reports the
negation. A per-activity direction flag was considered and rejected for slice
1: it is one more thing the instructor and the script have to agree on, and the
negation costs one character.

### The leaderboard

`leaderboard_entries` holds one row per (assignment, student): the best `metric`
any of their submissions reported, which submission reported it, and when. It
is written at result ingest by `recordLeaderboardEntry`, wired at **both**
ingest paths (the worker report and the browser result routes) beside
`recordClassItemCoverage`, and for the same reason: an accumulator wired at one
path reads as the whole class when it is only the half graded on one substrate.

A submission's metric is the highest any outcome in its collection reported.
The row is best-so-far, enforced by the unique constraint: a worse later run, a
re-test and a replayed report all leave it where it was, and a tie keeps the
earlier submission. Only a `.student` in the setup's own course ranks, so a
staff test run never takes a place. The `highestMetric` class record follows the
same event, higher wins, awarded outside the 100% gate the other four records
sit behind.

The page, `GET /testsetups/:id/leaderboard` (vanity
`/:courseCode/:assignmentSlug/leaderboard`), names a student by their per-course
handle and their chickadee, never by name. The avatar is the identity primitive
the leaderboard was designed on ([student-avatars.md](student-avatars.md) §3),
so the page has no identity code of its own: `AvatarStore` materialises the
handle and the spec on first view. Staff see a real name beside the handle,
because a grading dispute needs the mapping and nobody else does. Hidden by
default: a student reaches a hidden board as a 404, the same answer the vanity
routes give for anything a student is not meant to enumerate; staff always
reach it, with a chip saying it is hidden. The student's submission page links
the board once it is open to them.

### Runner contract (slice 2)

The runner will receive the opponent's workspace as a directory named by
`CHICKADEE_OPPONENT_DIR` and a per-match seed in `CHICKADEE_MATCH_SEED`, derived
from both submission IDs. Both ride the existing `CHICKADEE_` env allowlist in
`Sources/Worker/ScriptRunner.swift`. The opponent loop in the worker wraps
`executeSuites` and calls it once per opponent; `executeSuites` and
`interpretScriptOutput` in RunnerCore do not change.

### New tables

- `leaderboard_entries` (slice 1): (test_setup_id, user_id, submission_id,
  metric, reached_at), unique on (test_setup_id, user_id). FK to `users`,
  cascade.
- `match_results` (slice 4): (test_setup_id, submission_id,
  opponent_submission_id nullable, opponent_kind, round nullable, score, metric
  nullable, seed, created_at). Unique on (submission_id, opponent_submission_id,
  round).
- `tournament_runs` (slice 5): (test_setup_id, schedule, started_by,
  started_at, entrant snapshot as JSON, status, winner_user_id nullable).

Additive migrations only; no column changes to existing tables.

### Achievements

- `RecordDimension` gained `highestMetric` (slice 1) and is now `CaseIterable`;
  the "Ranked by" select, the JS rule summary and the MCP schema enum all
  derive from `RecordDimensionPresentation`, guarded by
  `RecordDimensionCoverageTests`. `tournamentWinner` and `champion` follow with
  their slices.
- `AchievementSignal` gains `standing` and `matchesWon` in slice 4. These read
  the whole class but award per student, a third category the current
  `readsTheWholeClass` split does not have (open question 1).
- `isSweepEvaluableClassGoal` admits exactly three shapes today. Extend the
  admitted list one shape at a time, each with its own test.

## Compatibility rules (every slice)

| Seam | Rule |
|---|---|
| `makeWorkerManifestJSON` writes a fresh dict | `activity` is threaded through every rebuild caller (both script edits, the family apply, the draft publish and the two draft suite rebuilds). `AssignmentHelpersManifestTests` pins the round trip. This is the `languageDeclared` trap, one field later. |
| Surgical edits | `setManifestActivity` is a `mutateManifest` edit like `setManifestMinimumRunnerVersion`, so fields this build does not model survive. |
| Old runners | `runnerSanitized()` drops the block (slice 1). Slice 2 adds the `activity-match` capability token and gates match jobs at claim with the `RunnerLanguageGate` pattern. |
| Browser grading | Slice 2 refuses `activity` with a non-`none` opponent source plus `gradingMode: browser` at the three doors that refuse `graderOnlyFiles`. A `bestMetric` assignment may be browser-graded; the metric rides the same collection. |
| Setup cache | The key hashes the manifest. Assignments without `activity` keep their key. |
| Versioning | Snapshots carry the manifest verbatim; `AssignmentVersionStoreTests` pins that the block survives. |
| Bundle export | The manifest travels as an opaque string. A bundle carrying a kind an older server does not know fails to decode on that server; note it in the term-clone runbook when the first such kind ships beyond slice 1. |
| UI | The Activity section renders only when the block is set. Built from the component vocabulary; `PAGE_STYLE_BASELINE` unchanged. |
| MCP | `set_activity` (kind locked once submitted) and `activityKinds` on `get_server_info`; every kind list derives from `ActivityKind.allCases` via `MCPActivityProse` (`MCPActivityCoverageTests`). |
| Versions | No edits to `VERSION`, `ChickadeeVersion.swift` or `CHANGELOG.md`; one fragment under `changelog.d/` per PR. |

## Authoring a slice-1 activity

1. Set the kind: the "Class activity" select on the edit page, or
   `set_activity` with `kind: "bestMetric"` or `"beatTheInstructor"`. Doing so
   seeds a `highestMetric` record achievement, curating the built-in records
   alongside it as a first Save of the Achievements table would, so Pathfinder
   and friends keep awarding.
2. Author one suite entry whose script measures the submission and prints a
   footer with `metric`. For `beatTheInstructor`, bundle the bot as a
   grader-only support file (which forces worker grading, as for a bug hunt)
   and have the script play the trials and report the win count as `metric`
   and the win fraction as `score`.
3. Publish the leaderboard when ready: the Activity section's checkbox or
   `set_activity` with `leaderboardVisibility: "visible"`.

## Open questions (decide during the named slice)

1. **Slice 4.** Does a matrix activity contribute to the grade of record, or
   only to achievements? Win fraction against classmates is not stable across
   the term, and the class-goal freeze rules assume a monotone number.
   Recommendation: achievements only in v1, with participation credit through
   an ordinary public test.
2. **Slice 4.** The `standing` signal reads the whole class but awards per
   student. Either add a third category to `AchievementSignal` or let the sweep
   evaluate individual achievements for that signal only. Recommendation: the
   second, with the sweep writing per-student rows.
3. **Slice 5.** Seeding order for brackets: submission order, a short
   qualifying round robin within groups, or random under a stored seed.
4. **Slice 1 follow-up.** A "Class activity" control on the create page, so the
   kind is chosen at creation as the design intends, rather than on the edit
   page in the window before the first submission.

## References in the repo

- `Sources/Core/ClassActivity.swift`, `Sources/Core/TestProperties.swift`
  (`activity`), `Sources/RunnerCore/OutputInterpretation.swift` (`metric`)
- `Sources/APIServer/Helpers/LeaderboardEntries.swift`,
  `Sources/APIServer/Models/APILeaderboardEntry.swift`,
  `Sources/APIServer/Routes/Web/WebRoutes+Leaderboard.swift`,
  `Resources/Views/leaderboard.leaf`
- `Sources/APIServer/Services/ActivityAuthoring.swift` (the lock and the
  seeded record, shared by the web edit page and `set_activity`)
- `Sources/APIServer/Helpers/ClassAchievements.swift`
  (`awardHighestMetricRecords`), `Sources/Core/Achievement.swift`
- `docs/collaborative-class-assignments.md`,
  `Sources/APIServer/Helpers/ClassItemCoverage.swift` (the ingest-time
  pattern this follows)
- `docs/student-avatars.md`, `Sources/APIServer/Services/AvatarStore.swift`
- `docs/runner-capability-profiles.md`,
  `Sources/APIServer/Compatibility/RunnerLanguageGate.swift` (slice 2)
- `docs/solution-visibility.md` for `postDeadlineRevealDeadline`
- `docs/ui-design.md` for the page archetype and the style ratchets
