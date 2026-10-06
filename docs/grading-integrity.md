# Grading integrity

How Chickadee stops a submission from changing its own grade or reading the
tests that grade it, and the plan to get there. Tracking issue: #2223.

| Phase | Issue | State |
|---|---|---|
| 0. Measure each attack, per language | #2239 | not started |
| 1. Confirm browser-graded results on a native runner after the deadline | #2240 | planned (D4 to D7) |
| 2. Per-test working directory and exit masks on the native runner | #2241 | done: other suite scripts hidden (#2248), exit guards for Python, R, Lua and Racket (#2244 to #2247); Octave waits for phase 3 |
| 3. Run the submission in a separate process | #2242 | **discuss before work starts** |

Decisions D1 to D3 below were agreed with the maintainer on 2026-10-05.

## What this document is not about

The runner sandbox (`--sandbox`) protects the server, the network and the other
jobs on a runner from a submission. The closed staff assignment `k6Szng` checks
it on every runner (#2061, #2225, #2237). This document is about the other
direction: protecting the grade from the student whose code runs. The sandbox
does not help there, because the submission and the test that grades it are
inside the same sandbox.

Resource limits between jobs are #2224.

## What a submission can do today

From reading the code on 2026-10-05. Phase 0 replaces this table with measured
results.

### Browser-graded assignments

The student's browser runs the suite and POSTs the finished
`TestOutcomeCollection` to `/api/v1/submissions/browser-result`.
`BrowserResultRoutes.submitBrowserResult` stores it as the final result and
queues no native run ("browser results are authoritative"). A native run
happens only on a browser failover or an instructor retest.

- A student can send any result for any submission with their own login. No
  change on the runner can fix this.
- The browser receives every suite script except grader-only files, so release
  and secret tests are readable in the developer tools.

### The native runner

Every generated test loads the submission into its own process: Python imports
it, R and Octave evaluate it, Lua loads it, Racket requires it, C++ compiles it
into the test program and Java into the test's JVM. Only the `programIO` kind
in C++ and Java runs the submission as a separate process, and even there the
checker source with the expected output is in the same directory.

| Attack | Python | R, Lua, Octave, Racket | C++, Java |
|---|---|---|---|
| Read every test script of every tier, and grader-only files | yes: all are in the one working directory | yes | yes |
| Read its own test's expected value | yes: same process | yes | yes |
| Report its own pass | yes: `sys.exit(0)` is not caught, and `passed` is a built-in | yes: no exit masks on native generated tests, and the runtime's `passed` is reachable | partly: the `CK_SENTINEL` check stops a plain `exit(0)`, but a submission can print the sentinel line itself |

The result of a test is its exit code and its last stdout line
(`interpretScriptOutput`). Nothing authenticates either one. The browser
kernels use a per-run nonce, but it only delimits the wrapper's own report: a
submission that exits with status 0 still reads as a pass.

## Decisions

**D1. Browser-graded results are confirmed on a native runner, once, after the
deadline.** Not every browser submission is graded again. When a student's
post-deadline moment has passed (`postDeadlineRevealDeadline`: the
extension-aware deadline, or the end of the slip-day claim window), the native
runner grades the student's submission with the best browser grade.

- If the native result agrees, the grade is confirmed.
- If it differs, the native runner grades the student's next-best browser
  submissions, best first, while a submission's browser grade is still above
  the best native grade found so far.
- From then on, the native result is the one that counts for each submission
  graded this way.

This needs a change to grade selection. Today the best grade wins across all
sources, and `bestGradeForStudent` says that "a 100 % browser result is never
displaced by a later lower worker re-grade". After phase 1, a native result
replaces the browser result of the same submission.

**D2. Order: phase 0, then phases 1 and 2, then phase 3.** Phase 3 starts with
a design discussion with the maintainer, not with code.

**D3. This document is the plan.** Each phase has its own issue, and each phase
ends with a staff check that proves it on the production runners.

Decisions D4 to D7 were agreed with the maintainer on 2026-10-06, for phase 1.

**D4. The deadline run counts at once.** There is no observe-only release. When
the native result of a deadline run arrives, it replaces the browser result of
that submission, also when it is lower. Two safeguards limit the cost of a real
difference between the graders: a native run that did not grade the
submission (the build failed or the runner reported a processing failure)
never replaces a grade, and staff see every disagreement.

**D5. Only a deadline run replaces a browser result.** An instructor retest,
before or after phase 1, keeps today's rule: the higher result counts. So no
grade changes when phase 1 deploys.

**D6. Only new deadlines are swept.** The sweep confirms an assignment only when
its post-deadline moment passes after phase 1 deploys. An instructor can start
confirmation of an earlier assignment with a button on the assignment.

**D7. What the browser receives is decided after phase 1.** It keeps every tier
until then. Once native results count, the browser could grade public tests
only, as a preview. That changes what students see before the deadline, so it
is its own change.

## Phases

### Phase 0: measure (#2239)

A closed staff assignment, like `k6Szng`, with one check per attack in each
language and on the browser path. Each check passes when the attack fails. It
also measures the cost of one extra interpreter start on the native runner,
because the docs have native start-up numbers only for C++ and Java.

### Phase 1: confirm browser results after the deadline (#2240)

As in D1 and D4 to D7.

**What exists.** Results are append-only rows (`APIResult`), each with a
`source` of `browser` or `worker`, so a native run adds a row beside the browser
row and overwrites nothing. Today the highest percent wins across every row
(`bestGradeResult` in `BestGradePercentBySubmissionID.swift`, used by the
BrightSpace and LTI sweeps, the grades CSV, the history pages and class goals),
and the instructor roster and the student dashboard repeat that rule in SQL
(`StudentSubmissionAggregates.swift`). `flipSubmissionToPending` queues a
native run of a browser submission, as the retest button does. Every worker
result already flags the student for BrightSpace and LTI sync.

**Design.**

1. **Confirmation state on the submission.** Nullable columns record that the
   sweep requested a deadline run, and its outcome: agreed, disagreed, or
   could not confirm. The sweep reads them, so it is idempotent.
2. **The sweep.** A `PeriodicSweepMonitor`, every five minutes. For each
   browser-graded assignment and each student whose post-deadline moment
   (`postDeadlineRevealDeadline`) has passed, it queues the student's best
   browser submission that has no confirmation, one at a time per student, at
   the lowest claim priority (after retests). When the native result arrives:
   - same grade percent: agreed, and the student is done;
   - different: disagreed, and the sweep queues the next-best browser
     submission while its browser grade is above the best native grade found
     so far;
   - no grade (a failed build or a processing failure): retried once, then
     "could not confirm", and the browser grade stays (D4).
   An assignment with no deadline is never swept.
3. **Selection.** One shared rule decides which result rows count: for a
   submission with a deadline-run result, only its worker rows count (D5). The
   Swift fold and both SQL folds use it, and a test checks that the three
   agree. The BrightSpace and LTI sweeps then push the new grade without
   further change.
4. **Staff view.** On the assignment's submissions page, a chip per student:
   pending, agreed, disagreed (browser x %, native y %) or could not confirm,
   and a filter for disagreements. A disagreement is a signal for the
   instructor, not an accusation. The page also has the button of D6.
5. **Staff check.** A closed staff assignment with a forged browser result: its
   grade must not survive the post-deadline moment.

**Pull requests, in order.**

1. The confirmation columns and the shared selection rule, with tests. No grade
   changes, because no deadline run exists yet.
2. The sweep, the stop rule and the result hook, with tests.
3. The staff view and the button for earlier assignments.
4. The staff check on the production runners.

### Phase 2: native hardening (#2241)

Cheap steps, each patch-sized. They do not stop a determined attacker, because
the expected value and the runtime's `passed` function stay in the same process
as the submission.

- Each test runs in its own working directory that holds only its own script,
  the runtime helpers, the submission and the files the test needs. The sandbox
  already shows a script only its working directory, so other tests become
  invisible.
- Native generated tests stop the submission from ending the test with its own
  exit status, as the browser kernels and `programIO` already do.

### Phase 3: a separate process for the submission (#2242)

The direction, not a decision: the submission runs in a child process, in a
second sandbox that shows only the submission files, and the test calls it
through a small message protocol. The verdict then comes from a process that
the submission cannot reach. The open questions are in #2242. Stop and discuss
before work starts.
