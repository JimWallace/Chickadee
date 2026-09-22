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
| 2 | Opponent primitive with `supportFile`: `CHICKADEE_OPPONENT_DIR` / `CHICKADEE_MATCH_SEED`, the `activity-match` runner capability, the browser-grading refusals | shipped |
| 3 | `champion` opponent (king of the hill): `kingOfTheHill`, `match_results` opened at claim and completed at ingest, `activity_champions`, the champion banner, `RecordDimension.champion`, the `activity-opponent-submission` runner capability | shipped |
| 4 | `classmates` matrix (round robin): `roundRobin`, `Job.opponents`, the per-match `MatchReport` rows, `activity_standings`, the standings page, `RecordDimension.tournamentWinner`, the `standing` / `matchesWon` signals, the `activity-matrix` runner capability | shipped |
| 5 | Tournaments: `elimination` (single-elimination bracket or Swiss), the `paired` opponent source, `tournament_runs` / `tournament_matches`, `tournamentMatch` submissions, the Run tournament control and MCP `run_tournament`, the bracket page | shipped |
| 6 | Tests and code (asymmetric reading of the matrix): `testsVersusImplementations`, the `union` aggregation, the two-table class page | shipped |
| 7 | Synthetic class submission (coverage percent) | not started |
| 8 | Live-session controls (`openWindow`, countdown, auto-refresh) | not started |

One thing a reader should not go looking for after slice 4: **the web create
page has no activity control.** The kind is chosen on the edit page (the "Class
activity" select) or through MCP `set_activity`, either of which is free until
the first student submission. Creation-time choice is a follow-up.

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
| `kingOfTheHill` | `champion` (whoever holds the hill; the bundled bot until a student does) | `leaderboard` | `record` on `highestMetric`, `record` on `champion` | 3 (shipped) |
| `roundRobin` | `classmates` (every classmate's latest submission; the bundled bot until one exists) | `standings` | `record` on `tournamentWinner`; `standing` / `matchesWon` badges are authored | 4 (shipped) |
| `elimination` | `paired` (the one entrant a schedule pairs the job with; the bot for a student's own submission) | `bracket` | `record` on `tournamentWinner` | 5 (shipped) |
| `bugHunt` | `variants` (instructor's seeded variants) | `union` | already shipped, re-described only | — |
| `testsVersusImplementations` | `classmates` (the same matrix a round robin plays) | `union` — every match read twice, as a kill and as a fault | nothing; the page is the reward surface | 6 (shipped) |

`ActivityKind` (`Sources/Core/ClassActivity.swift`) carries only the kinds that
work end to end. A kind the runner cannot execute is a silent misroute, not a
feature, so each arrives with the slice that makes it grade. The opponent axis
is a type of its own since slice 2: `ActivityOpponentSource` (`none` |
`supportFile`), read off the kind by the exhaustive `opponentSource`, so a kind
added without an answer does not compile. Every seam that depends on an
opponent — the worker's `activity-match` capability, the claim gate, the
browser-grading refusal, the opponent picker — asks `stagesAnOpponent`, never
the kind. The aggregation axis is still the one derived fact
`aggregatesToLeaderboard`; it becomes a type when standings land.

### Manifest block (Core, `TestProperties.activity`)

```json
"activity": {
  "kind": "beatTheInstructor",
  "leaderboardVisibility": "hidden",
  "opponentFile": "bot.py"
}
```

Every field but `kind` decodes with a default. `opponentFile` (slice 2) names
the support file the worker stages as the opponent for a kind whose source is
`supportFile`; it is omitted from the bytes when nil, so a slice-1 block is
unchanged. Later slices add `trialsPerMatch`, `schedule` and `freezeAt` (nil
meaning the assignment deadline, resolved through `postDeadlineRevealDeadline`
so the slip-day claim window is honoured) as they are used, not before.

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

### Runner contract

A match job's script receives the opponent's workspace as a directory named by
`CHICKADEE_OPPONENT_DIR` and a per-match seed in `CHICKADEE_MATCH_SEED`. Both
ride the existing `CHICKADEE_` env allowlist in `Sources/Worker/ScriptRunner.swift`,
and an ordinary job sets neither, so its environment is byte-for-byte what it
was. `executeSuites` and `interpretScriptOutput` in RunnerCore do not change;
the opponent loop that calls the suite once per classmate is slice 4's.

**What the runner is told, and why it is not the enum.** The `activity` block
never reaches the runner (`runnerSanitized()` strips it), so a match's needs
travel on the job: `Job.opponent` (`Core/JobOpponent.swift`) is structural — the
support file to stage and the seed — and names no kind and no source. A later
source adds a field beside `supportFile`, not a case an old runner's decoder
would choke on. The seed is `JobOpponent.matchSeed(submissionID:opponentIdentity:)`,
a SHA-256 of the submission ID and the opponent's identity with the source
spelled in front (`supportFile:bot.py`), so a re-test replays the same trials,
two students never share one, and a bot named like a submission ID cannot
collide with it.

**Where the opponent is staged.** `stageOpponentWorkspace`
(`Sources/Worker/OpponentStaging.swift`) copies the named support file into
`<job work dir>/opponent/` under its own name — beside the test-setup
directory, not inside it, so the script's working directory gains no stray
entry the submission-file candidates would have to ignore. Both sandboxes read
it (the macOS profile reads the whole filesystem; the Linux namespaces do not
restrict reads), and it is removed with the job. Because the file keeps its
name, an instructor who names the bot the way the student's required file is
named (`strategy.py` against `strategy.py`) can write one match script that
reads `$CHICKADEE_OPPONENT_DIR/strategy.py` today and will read a classmate's
staged submission the same way in slice 4.

**An opponent is staged only once a file is chosen.** `stagesAnOpponent` needs
both a kind whose source stages one and an `opponentFile`. Until the instructor
chooses the bot, the job carries no opponent, no gate applies and browser
grading is not refused: the assignment grades exactly as a slice-1 activity did,
on any runner, with a hand-wired bot if the script has one — so shipping the
primitive changed no existing assignment's path. The picker renders for the
kind (`takesAnOpponentFile`) and says nothing is staged until a file is chosen;
a script written for the primitive fails on its own when the directory is unset
(the fixture exits 2 with "no opponent staged").

**Failing loudly.** A job that does carry an opponent whose file is not a bare
filename or is missing from the setup (deleted after it was chosen) fails with
`buildStatus: failed` and a message naming the fix
(`WorkerDaemonError.opponentFile*`); the worker also refuses a descriptor
naming no file, which the server never sends. A match with nobody on the other
side would read as a win, so the worker refuses to run it — and since instructor
validation is a `.validation` submission graded on the native worker, the gap
shows on the validation run, not in a student's grade.

**The claim gate.** `RunnerActivityGate` (the fourth sibling at the claim seam,
shaped like `RunnerLanguageGate`) refuses a match job to a runner whose profile
does not list the `activity-match` capability. It is a *build* capability
(`RunnerProfileDetector.buildCapabilities`): nothing has to be installed, the
runner just has to know how to read `Job.opponent`. An older build never
advertises it — and would otherwise decode the job without the key and grade
the bot match with no bot in the workspace, silently. Fails open, like the
language gate, for an activity with no opponent and for a runner advertising
no profile at all.

**Browser grading is refused** for any activity that stages an opponent (a bot
kind with its file chosen, or a hill kind at all), at the same doors that refuse grader-only files: the
zip upload, `set_grading_mode` (and the web mode change and section adoption
through `setManifestGradingMode`), and choosing the file through `set_activity`
or the picker from the other side. One message,
`activityOpponentGradingConflictMessage`. A `bestMetric` assignment may still be
browser-graded. Slice 1's advice to mark the bot grader-only stands, for a
different reason now: worker grading is forced by the opponent itself, and
`graderOnly` is what keeps the bot's *source* out of students' hands.

### New tables

- `leaderboard_entries` (slice 1): (test_setup_id, user_id, submission_id,
  metric, reached_at), unique on (test_setup_id, user_id). FK to `users`,
  cascade.
- `match_results` (slice 3): (test_setup_id, submission_id,
  opponent_submission_id nullable, opponent_identity, round nullable, score,
  metric, won, seed, created_at, completed_at nullable). Unique on
  (submission_id, opponent_identity) — the identity rather than the nullable
  submission ID, so a bot opponent keys too. Slice 4 fills `round`.
- `activity_champions` (slice 3): (test_setup_id unique, user_id, submission_id,
  crowned_at, defences). FK to `users`, cascade.
- `activity_standings` (slice 4): (test_setup_id, user_id, submission_id,
  played, wins, draws, losses, score_sum, updated_at), unique on
  (test_setup_id, user_id). Recomputed from the student's LATEST submission's
  completed `match_results` rows at every ingest — never best-so-far. FK to
  `users`, cascade.
- `tournament_runs` (slice 5): (test_setup_id, schedule, started_by,
  started_at, entrants as `[TournamentEntrant]` JSON, status
  `running | complete | superseded`, current_round, round_count,
  winner_user_id nullable, completed_at nullable). Every run is kept;
  starting another supersedes the running one.
- `tournament_matches` (slice 5): (tournament_id FK cascade, round,
  position, home_seed, away_seed nullable, match_submission_id nullable,
  winner_seed nullable, completed_at nullable), unique on (tournament_id,
  round, position). The bracket's structure; a match's score, metric and
  seed stay on the `match_results` row the claim opens for its job, with
  `round` set.

Additive migrations only; no column changes to existing tables.

### Achievements

- `RecordDimension` gained `highestMetric` (slice 1), `champion` (slice 3,
  a held record: the hill's holder) and `tournamentWinner` (slice 4, held the
  same way: the standings leader) and is `CaseIterable`; the "Ranked by"
  select, the JS rule summary and the MCP schema enum all derive from
  `RecordDimensionPresentation`, guarded by `RecordDimensionCoverageTests`.
- `AchievementSignal` gained `standing` and `matchesWon` (slice 4). They were
  expected to need a third category beside `readsTheWholeClass`; they do
  not. They are classified STATIC, like `grade`: an authored badge carrying
  one is an `isAuthorableIndividualBadge`, evaluated on the submission page
  (`earnedIndividualBadges`), which loads the student's current standings
  for a round robin (`standingSignals`) and passes them in. Anywhere they
  are not loaded the condition is unmet, and a class goal carrying one is
  refused by `isSweepEvaluableClassGoal`, so the sweep never sees them.
- `isSweepEvaluableClassGoal` admits exactly three shapes today. Extend the
  admitted list one shape at a time, each with its own test.

### King of the hill (slice 3)

`kingOfTheHill` (chrome label "Beat the champion") is the first kind whose
opponent is another student's SUBMISSION. Its opponent source is `champion`,
and the kind stages one whether or not a bot is chosen, so the kind itself is
worker-only: `stagesAnOpponent` is true for it unconditionally, `set_activity`
refuses it on a browser-graded assignment, and its jobs need a runner build
advertising `activity-opponent-submission` — a second token beside
`activity-match`, because a slice-2 build that copies a support file would
fail every hill match (loudly, but for every student until a runner is
upgraded), and `ActivityOpponentSource.requiredRunnerCapability` is where a
source names the token its jobs need.

**Two tables, and the claim path writes one of them.** `activity_champions`
holds one row per assignment: who holds the hill, which of their submissions
does, when they took it, and how many challengers they have turned back
(`defences`, the streak the leaderboard shows). `match_results` holds one row
per (submission, opponent identity), OPENED when the job is built and
COMPLETED when its result lands. That is how the result path knows which
opponent the job actually played — the champion may have changed while the job
was out — without the worker echoing it back and without a column on
`submissions`. The unique key is what makes ingest idempotent: a replayed
report finds its row completed and does nothing; a re-test reopens the same
row rather than adding one.

**Who a challenger plays** (`chooseOpponent`): the current champion's
submission, unless the challenger IS that submission — a re-test of the
champion plays the bot, never itself — else the bundled bot (`opponentFile`),
else nobody. A champion who resubmits does play their own earlier entry. The
job then carries `JobOpponent.submissionURL` / `submissionFilename`
(a worker download URL for the champion's upload) instead of `supportFile`;
the worker downloads it through the same retrying download the challenger's
upload gets and stages it the way the challenger's is staged — raw file under
its submitted name, zip extracted, every notebook extracted to the assignment's
source language, and `.chickadee_student_module` naming the opponent's module,
so a match script finds the opponent's code by the same hint the runtimes use
for the student's.

**How the hill moves** (`recordActivityMatch`, each rule pinned by
`ActivityChampionTests`). The match entry is the outcome with the highest
reported `metric`, and the challenger WON when that entry passed — the script's
exit code is the verdict, `score` its credit, `metric` its rank, exactly the
existing contract. Then:

- a replayed report finds no open row and does nothing;
- a re-test of the champion's own submission never moves the hill (it played
  the bot);
- the challenger takes the hill when they won AND the opponent they played is
  still the hill's holder — a win against a champion who has since been
  replaced crowns nobody (the student beat the wrong opponent; a re-test plays
  the right one);
- a champion beating their own earlier entry moves the hill's submission
  forward and keeps the streak;
- a loss to the current champion counts one defence;
- only a `.student` in the setup's own course can hold the hill, so a staff
  validation run completes its row and changes nothing.

The leaderboard still ranks on `metric` (a win count, typically) and gains a
line naming the hill's holder by handle and bird, with "since" and the streak;
staff also see the name. `RecordDimension.champion` is a HELD record rather
than a ranked one — `awardChampionRecords` makes the new holder the record's
holder outright — and `set_activity` seeds it (`hill_champion`) beside the
leaderboard record, removing it again when the kind changes away from the hill.

Authoring is slice 2's recipe with one change of meaning: the bot in
`opponentFile` is the hill's FIRST holder, not its only opponent, and the
match script must exit 0 only when the challenger beat whoever is in
`CHICKADEE_OPPONENT_DIR` — the fixture's rock-paper-scissors script already
does, and `OpponentStagingTests` plays it against a staged champion.

### Round robin (slice 4)

`roundRobin` is the first kind whose opponents are MANY submissions, and the
first whose class aggregation is not a metric ranking. Its opponent source is
`classmates`; its aggregation is `standings`. Like the hill it is worker-only
by construction (`stagesAnOpponent` unconditionally, refused on a
browser-graded assignment), and its jobs need a runner build advertising
`activity-matrix`, a third token beside the two before it: a slice-3 build
stages one submission and would grade a matrix job against nobody.

**Who a challenger plays** (`chooseClassmates`): the latest complete
submission of every OTHER `.student` enrolled in the setup's course, one per
classmate, in submission-id order. Latest by submission time, so a
resubmission by B changes what A's NEXT job plays and never what A's landed
job played. When no classmate has submitted yet, the challenger plays the
bundled bot on the single-opponent path (or nobody, when there is no bot), so
the first submitter still has a match and a row. The claim opens one
`match_results` row per opponent — the same open-at-claim, complete-at-ingest
shape as the hill — and the job carries `Job.opponents`, a list of the same
structural `JobOpponent` the hill's `Job.opponent` is; a runner that predates
the field decodes the job without it, which is why the gate exists.

**What the worker does.** It downloads and stages every opponent up front,
each into its own `opponent-<index>/`, so a download failure fails the job
before any match is played rather than after most of them. Then it runs the
suite once per opponent with that opponent's `CHICKADEE_OPPONENT_DIR` and
`CHICKADEE_MATCH_SEED`, and folds the runs (`MatrixAggregation.swift`) into
ONE outcome per suite entry — `Tests/Fixtures/output-contract.json` never
learns a second shape — where `score` is the mean, `metric` the sum, the
status `error` / `timeout` if any run was and otherwise `pass` when at least
half the matches were won, and stderr is joined under a header naming each
opponent so staff can read every match. Beside the collection the report
carries one `MatchReport` per run (`WorkerExecutionReport.matches`): the
opponent's identity, the seed, and the match entry's `score`, `metric` and
verdict. A report from a runner that predates the field decodes with none.

**How the standings move** (`recordMatrixMatches`, pinned by
`ActivityStandingsTests`). The reports complete the open rows by opponent
identity; a row the worker never reported stays open and counts nothing; a
bot-only job (no reports) completes its one row from the collection's match
entry as a hill match does; a replayed report finds no open row and does
nothing. Then the challenger's `activity_standings` row is REWRITTEN from
that submission's completed rows — played, won, drawn (not won, score exactly
one half), lost, and the score sum — and only theirs: a classmate's standings
count only their own latest submission's matches, so a landed result changes
nothing about anyone else, and a resubmission supersedes rather than deletes.
The standings order is average match score, then wins, then matches played,
then the earlier row; whoever leads holds the `tournamentWinner` record
(`awardTournamentWinnerRecords`, a held record like `champion`). Only a
`.student` in the setup's course stands.

**What the page shows.** The leaderboard page switches on
`ActivityKind.aggregation`: a standings kind shows played, won, drawn, lost
and average by handle and bird, best first, instead of the metric table
(`buildStandingRows`, sharing `RankedIdentities` with the metric rows), and
`recordLeaderboardEntry` writes no metric row for it. `set_activity` seeds the
`standings_leader` record INSTEAD of the leaderboard record and swaps them
back when the kind changes to a metric kind.

**The grade of record is untouched** (open question 1, decided): a round robin
contributes to achievements only. Win fraction against classmates is not
stable across the term, so participation credit belongs in an ordinary public
test beside the match entry.

**Cost.** A matrix job runs the suite N times for N classmates, so the K-th
submission costs K−1 suite runs; a class of S students that each submit once
costs S(S−1)/2 runs, and each resubmission costs another S−1. A subprocess
suite costs at least ~100 ms, so 300 students submitting once is at least 45
000 runs, about 75 minutes on one runner — and that is the floor, before the
script's own work. Budget the match script's rounds accordingly, and prefer a
worker with several concurrent jobs; slice 5's brackets are the answer for a
class where every-pair play is too expensive.

### Tournaments (slice 5)

`elimination` (chrome label "Tournament") is the first kind whose matches
are not a student's own submission being graded. An instructor starts a run —
the submissions page's Tournament section or MCP `run_tournament`, choosing
`bracket` (single elimination) or `swiss` at that moment rather than on the
manifest, since one assignment may host both across a term — and the run
snapshots every enrolled `.student`'s latest complete submission as its
entrants, seeded in the order those submissions arrived (open question 3,
decided: submission order). Fewer than two entrants is refused. A student who
resubmits after the start plays with the snapshotted entry; a run already in
progress is marked superseded (its landed matches keep their rows, its
outstanding jobs still decide their slots but move nothing), so a stalled run
can never block the class.

**A match is a submission.** Each pairing enqueues one `tournamentMatch`
submission — a frozen copy of the home entrant's upload (same file, same
filename, the entrant's user) — claimed after fresh student work and before
validation. Its job stages the away entrant's snapshotted submission on the
hill's single-opponent contract, which is why the kind's opponent source is
`paired` and its runner token is `activity-opponent-submission`, not a fourth
one: the axis names what is in the workspace and how many times the suite
runs, and a bracket match is one opponent, once. The claim opens the
`match_results` row with `round` set. A match submission is never a grade of
record: every listing, aggregate, badge path and grade selection filters on
`kind == student`, and the result path routes it to `recordTournamentMatch`
alone. A student's own submission on such an assignment plays the bundled bot
as practice (no row) and grades as it always did.

**How a round moves.** The script's exit code decides the slot: a pass means
the home entrant won, and anything else — a loss, an error, a timeout, a
build failure — advances the away entrant, so a broken submission can never
stall a round. When the current round's last slot is decided the next round
is enqueued from the pure pairing rules (`TournamentPairing` in Core, tested
on five, eight and nine entrants); when none is, the run completes and the
winner holds the `tournamentWinner` record (`tournament_winner`, seeded by
`set_activity` for a bracket kind in place of the standings leader). A
replayed report finds its slot decided and does nothing.

**The two schedules.** A bracket seeds entrants into the next power of two in
the standard order (1 meets N, 2 meets N−1, …), so the byes fall to the top
seeds and the top seeds cannot meet before the final; a bye is stored already
won. Swiss plays ceil(log2 N) rounds; each round ranks entrants by points (a
win or a bye is one), pairs neighbours avoiding a rematch where one can be
avoided, and gives an odd field's bye to the lowest-ranked entrant who has
not had one; the most points wins, fewest byes then better seed breaking a
tie. There are no draws.

**Where it shows.** The leaderboard page switches on `aggregation == .bracket`
to the latest run: its schedule and status, the winner once there is one,
and every round's matches by handle and bird (staff also see names). The
submissions page carries the control — the schedule select, the button, one
line on where the latest run stands — and links the bracket rather than
repeating it. `get_server_info` still reports every kind's aggregation as
"leaderboard": `SetActivityToolTests.serverInfoListsEveryKind` pins that
value, and changing it is a decision for that test's owner.

### Tests and code (slice 6)

`testsVersusImplementations` (chrome label "Tests and code") is the first
kind whose class reading is a **union** rather than a ranking. Every student
submits both tests and code; one job runs their tests against every
classmate's latest submission, exactly as a round robin does. What is new is
that each landed match is read TWICE — as a kill for the student whose test
found the fault, and as a fault against the classmate whose code was tested.

**It reuses the matrix outright.** The opponent source is `classmates`, so
the claim path, the worker's per-opponent loop, the `activity-matrix`
capability and the `MatchReport` rows are slice 4's, unchanged. Slice 6 adds
no table, no migration, no runner token and no worker code. Two kinds now
share one opponent source and differ only in aggregation, which is the axis
pair doing the job it was built for.

**It materialises nothing** (`ActivityUnion.swift`). Every other aggregation
writes a row at ingest because it answers a question the stored outcomes
cannot answer cheaply; this one can, because a union over matches is a query
over the rows the matrix already completed — which is what
[collaborative-class-assignments.md](collaborative-class-assignments.md)
says a bug-set union is. A stored number would answer the tester's half only,
and that half reads as the whole record. So a union kind writes no
`activity_standings` row and moves no record, and `unionTally` reads both
halves in four queries.

**The two halves scope differently, deliberately.** A KILL belongs to the
student whose test found the fault and stays theirs after the author fixes
it: their work is not undone by somebody else's later submission. A DEFENCE
belongs to the author's CURRENT submission only, because the question it
answers is whether the code that stands today has held up — so a
resubmission returns that student to "not tested yet" until a classmate's
next run reaches it. This is the same asymmetry `class_item_coverage`
already carries between coverage and breadth, and it is safe here for a
reason worth stating: a union kind feeds achievements only, and
`isSweepEvaluableClassGoal` admits no shape that reads these rows, so a
number that moves when a student resubmits can never freeze into a grade
push. That is why this number may move at all, where a coverage count must
never retreat.

**The page** shows the count ("7 of 24 submissions defeated so far") over two
tables by handle and bird: Tests (what each student's tests defeated, and how
many classmates they ran against) and Code (how many classmates' tests each
submission has faced, and whether it is holding, defeated, or not tested
yet). Staff also see names. `set_activity` seeds no record for a union kind:
neither held record it could borrow means what a union means, and an
instructor who wants one authors it.

**Where this departs from the plan in #1508**, which called for an
`asymmetric` flag splitting the class into testers and implementers by
contribution slot: there are no roles. Everyone writes both, which removes
the role assignment, the authoring affordance for it, and the "a student in
neither role is refused at submit" case — three pieces of machinery for a
split that also halves what each student practises. The asymmetry the kind
is named for is real and survives: it is in how each match is READ, not in
who plays. The match script decides what counts as a fault, as the script
contract always has.

## Compatibility rules (every slice)

| Seam | Rule |
|---|---|
| `makeWorkerManifestJSON` writes a fresh dict | `activity` is threaded through every rebuild caller (both script edits, the family apply, the draft publish and the two draft suite rebuilds). `AssignmentHelpersManifestTests` pins the round trip. This is the `languageDeclared` trap, one field later. |
| Surgical edits | `setManifestActivity` is a `mutateManifest` edit like `setManifestMinimumRunnerVersion`, so fields this build does not model survive. |
| Old runners | `runnerSanitized()` drops the block (slice 1). `RunnerActivityGate` keeps a match job away from a runner not advertising the source's token — `activity-match` for a bot (slice 2), `activity-opponent-submission` for a hill (slice 3) and for a tournament's paired match (slice 5, the same contract), `activity-matrix` for a round robin and for tests-and-code (slices 4 and 6, the same contract); a new opponent source adds a FIELD to `JobOpponent` (or a list of them, `Job.opponents`) and a token to `requiredRunnerCapability`, never an enum the runner decodes. A runner's report may carry `matches`; a server reads them optionally. |
| Browser grading | `stagesAnOpponent` plus `gradingMode: browser` is refused at every door that refuses `graderOnlyFiles` (slice 2). A `bestMetric` assignment may be browser-graded; the metric rides the same collection. |
| Visibility and opponent edits | `withLeaderboardVisibility` / `withOpponentFile` rebuild the block from the stored one, so neither surface's edit can drop the other's field. The edit page's kind select carries the stored block forward when the kind is unchanged. |
| Setup cache | The key hashes the manifest. Assignments without `activity` keep their key. |
| Versioning | Snapshots carry the manifest verbatim; `AssignmentVersionStoreTests` pins that the block survives. |
| Bundle export | The manifest travels as an opaque string. A bundle carrying a kind an older server does not know fails to decode on that server; note it in the term-clone runbook when the first such kind ships beyond slice 1. |
| UI | The Activity section renders only when the block is set. Built from the component vocabulary; `PAGE_STYLE_BASELINE` unchanged. |
| MCP | `set_activity` (kind locked once submitted) and `activityKinds` on `get_server_info`; every kind list derives from `ActivityKind.allCases` via `MCPActivityProse` (`MCPActivityCoverageTests`). |
| Versions | No edits to `VERSION`, `ChickadeeVersion.swift` or `CHANGELOG.md`; one fragment under `changelog.d/` per PR. |

## Authoring an activity

1. Set the kind: the "Class activity" select on the edit page, or
   `set_activity` with `kind: "bestMetric"` or `"beatTheInstructor"`. Doing so
   seeds a `highestMetric` record achievement, curating the built-in records
   alongside it as a first Save of the Achievements table would, so Pathfinder
   and friends keep awarding.
2. For `beatTheInstructor`, upload the bot as a support file (mark it
   grader-only to keep its source from students) and choose it: the Activity
   section's "Opponent file" select, or `set_activity` with `opponentFile`.
   The order does not matter — the kind may be set first — but nothing is
   staged until a file is chosen, and choosing one needs worker grading (it
   is refused on a browser-graded assignment).
3. Author one suite entry whose script plays the trials and prints a footer
   with `metric`. The script finds the bot at
   `$CHICKADEE_OPPONENT_DIR/<opponentFile>` and a per-match seed in
   `$CHICKADEE_MATCH_SEED`; report the win count as `metric` and the win
   fraction as `score`. For `bestMetric` the script measures the submission on
   its own; neither variable is set.
4. Publish the leaderboard when ready: the Activity section's checkbox or
   `set_activity` with `leaderboardVisibility: "visible"`.

A match script for rock-paper-scissors, as the fixture
`Tests/Fixtures/activity-match/match_rps.sh` plays it: it exits 2 unless both
variables are set and the bot is where they say, plays five rounds calling the
submission's and the bot's `python3 strategy.py <round-history>`, reports the
seed and the history on stderr, and prints `{"score": wins/5, "metric": wins}`.
The worker test runs it end to end, and again with no opponent to prove it
errors rather than passes.

## Open questions (decide during the named slice)

1. **Slice 4 — decided.** A matrix activity contributes to achievements only;
   see "Round robin" above.
2. **Slice 4 — decided, differently from both options.** `standing` and
   `matchesWon` needed neither a third category nor the sweep: they are static
   authorable-badge signals evaluated on the submission page with the
   standings it loads. See "Achievements" above.
3. **Slice 5 — decided.** Brackets seed by submission order (1 = first to
   submit), the simplest rule a class can predict; see "Tournaments" above.
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
  (`awardHighestMetricRecords`, `awardChampionRecords`,
  `awardTournamentWinnerRecords`), `Sources/Core/Achievement.swift`
- `Sources/APIServer/Helpers/ActivityMatches.swift` (`chooseOpponent`,
  `chooseClassmates`, `openMatch`, `recordActivityMatch`, the standings),
  `Sources/APIServer/Models/APIMatchResult.swift`, `APIActivityChampion.swift`,
  `APIActivityStanding.swift`
- `Sources/Core/JobOpponent.swift` (`JobOpponent`, `MatchReport`,
  `matchOutcome`), `Sources/Worker/OpponentStaging.swift`,
  `Sources/Worker/MatrixAggregation.swift`
- `Sources/APIServer/Helpers/ActivityUnion.swift` (`unionTally`, both halves
  of a union kind's reading)
- `Sources/Core/Tournament.swift` (`TournamentSchedule`, `TournamentPairing`),
  `Sources/APIServer/Helpers/Tournaments.swift` (start, enqueue, pair, land,
  advance), `Sources/APIServer/Models/APITournamentRun.swift`,
  `Sources/APIServer/MCP/Tools/RunTournamentTool.swift`
- `docs/collaborative-class-assignments.md`,
  `Sources/APIServer/Helpers/ClassItemCoverage.swift` (the ingest-time
  pattern this follows)
- `docs/student-avatars.md`, `Sources/APIServer/Services/AvatarStore.swift`
- `Sources/Core/JobOpponent.swift`, `Sources/Worker/OpponentStaging.swift`,
  `Sources/APIServer/Compatibility/RunnerActivityGate.swift` (slice 2)
- `Sources/APIServer/Helpers/ActivityMatches.swift`,
  `Sources/APIServer/Models/APIMatchResult.swift`,
  `Sources/APIServer/Models/APIActivityChampion.swift` (slice 3)
- `docs/runner-capability-profiles.md`,
  `Sources/APIServer/Compatibility/RunnerLanguageGate.swift` (the gate's shape)
- `docs/solution-visibility.md` for `postDeadlineRevealDeadline`
- `docs/ui-design.md` for the page archetype and the style ratchets
