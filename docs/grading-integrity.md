# Grading integrity

How Chickadee stops a submission from changing its own grade or reading the
tests that grade it, and the plan to get there. Tracking issue: #2223.

| Phase | Issue | State |
|---|---|---|
| 0. Measure each attack, per language | #2239 | not started |
| 1. Confirm browser-graded results on a native runner after the deadline | #2240 | on hold: what a browser grade is for is proposed in D8 |
| 2. Per-test working directory and exit masks on the native runner | #2241 | done; grader-only files moved to phase 3 (see "Phase 2") |
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

From reading the code, first on 2026-10-05 and again after phase 2 on
2026-11-05. Phase 0 replaces these tables with measured results.

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
| Read the other test scripts of the job | no on a sandboxed runner: each one is covered while another runs; yes on an unsandboxed runner | same | same |
| Read a grader-only file | yes: support files stay readable, because tests use them and no link says which test uses which | yes | yes |
| Read its own test's expected value | yes: same process | yes | yes |
| Report its own pass with the language's exit call | no: a `SystemExit` raised through the submission's code, `passed()` included, is reported as an error | no: the call raises an error in place of exiting | partly: the `CK_SENTINEL` check stops a plain `exit(0)`, but a submission can print the sentinel line itself |
| Report its own pass another way | yes: `os._exit(0)` ends the process with no `SystemExit` | yes: the real exit is reachable by another name (`base::quit`, `_G.os.exit`, Octave's `builtin("exit")`) and so is the runtime's `passed` | yes: as above |

The last row is what phase 2 leaves open. It needs phase 3.

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

### D8 (proposed 2026-11-05): what a browser grade is for

**Status: proposed, not agreed.** Phase 1 has been on hold since 2026-10-06,
because how much protection a browser result needs depends on what the grade
is for. The draft design in #2264 assumed a grade that must be trusted. This
section states the use case and the options, so the maintainer can decide
before any phase 1 code is written. If D8 is agreed, it replaces D1.

**The use case.** Browser grading serves short, time-constrained work: lecture
activities and in-class exercises, where the grade rewards taking part. The
instructor cares less that each result is correct, and less that the solution
stays secret. Work where the grade must be correct already has a choice: an
assignment declares `gradingMode` as `browser` or `worker`, and a
worker-graded assignment is graded on a native runner only.

**Two facts from the code** (2026-11-05):

- The server checks that the student is enrolled, that the assignment is open,
  and that the payload decodes. It recomputes the total from the outcomes and
  sets the submission ID and attempt number itself. It does not compare the
  outcomes with the suite: test names, tiers and points come from the browser.
  A forged payload therefore needs no knowledge of the suite to read as 100 %.
- The optional `metric` comes from the browser too, and a class activity's
  leaderboard sorts on it. A forged result can therefore top a leaderboard.

**Options.**

| | A. Participation grade | B. Trusted grade (#2264) | C. Per assignment |
|---|---|---|---|
| What a browser grade means | the student ran the work; the grade is a self-check | the grade counts after a native run confirms it | the instructor picks A or B on each assignment |
| A forged result | is accepted; staff can spot-check with a retest | does not survive the post-deadline moment | as chosen |
| Release and secret tests | stay readable in the browser | the browser could grade public tests only (D7) | as chosen |
| Work | a few small PRs | four PRs, with new columns, a sweep and changes to every grade fold | B plus a new setting and its interface |
| Runner load | none | one native run per student per assignment, or more | as chosen |

**Recommendation: A.** It matches the use case, and `gradingMode: worker`
already covers work whose grade must be trusted. B protects a grade that the
use case does not need to protect, at the cost of the largest change in this
plan. C costs more than B and adds a second setting beside `gradingMode` that
says almost the same thing.

**If A is agreed, the work is:**

1. **Say what a browser grade means.** The authoring choice of `gradingMode`
   and `docs/architecture.md` state that a browser grade is a self-check, and
   that work whose grade must be correct uses worker grading.
2. **Make a spot-check visible.** A retest already grades a browser submission
   on a native runner, but the best grade wins, so a forged 100 % is not
   displaced, and nothing shows that the two results differ. Show staff, for
   each submission with both, when the browser and native results disagree. A
   disagreement can be a forged result or a real difference between the
   graders, so it is a signal, not an accusation.
3. **Optional: take the suite's shape from the server.** Ignore an outcome
   whose test is not in the suite, and take each test's points and tier from
   the manifest. This stops a careless forgery, not a deliberate one, so it
   only earns its place if leaderboards (`metric`) need it.
4. **Close what A makes unnecessary.** Close #2264 unmerged, and retitle #2240
   to the work above. D7 lapses: release and secret tests stay in the browser.

**Questions for the maintainer.**

- Is A agreed?
- Do class-activity leaderboards need more than A gives them? A forged
  `metric` is the one place where a browser result affects other students.

## Phases

### Phase 0: measure (#2239)

A closed staff assignment, like `k6Szng`, with one check per attack in each
language and on the browser path. Each check passes when the attack fails. It
also measures the cost of one extra interpreter start on the native runner,
because the docs have native start-up numbers only for C++ and Java.

### Phase 1: confirm browser results after the deadline (#2240)

As in D1. Also:

- re-push the grade to BrightSpace or LTI when confirmation changes it;
- show staff each disagreement between a browser result and its native
  confirmation. A disagreement can mean a forged result or a real difference
  between the browser and native graders, so it is a signal, not an accusation;
- decide whether release and secret scripts still reach the browser. Once the
  native run is authoritative, the browser could grade public tests only, as a
  preview.

### Phase 2: native hardening (#2241)

Cheap steps, each patch-sized. They do not stop a determined attacker, because
the expected value and the runtime's `passed` function stay in the same process
as the submission.

What shipped:

- **Other suite scripts are hidden.** The issue asked for a working directory
  per test. The sandbox does the same job in the one shared directory: while a
  suite script runs, it covers each of the job's other suite scripts with
  `/dev/null` on Linux and denies them in the profile on macOS
  (`NativeScriptExecutor.suiteScripts`). This holds on a runner started with
  `--sandbox`, as all three production runners were on 2026-10-06 (#2348). An
  unsandboxed runner hides nothing.
- **Exit masks, in the injected runtimes.** The runner writes `test_runtime.*`
  into every job, so a mask there covers every assignment at once, with no
  re-save of its generated tests. Python: the native bootstrap
  (`ScriptInvocation.swift`) reports a `SystemExit` whose traceback passes
  through a submission file as an error. R and Lua: the submission's
  environment gets its own `quit`/`q` and `os`. Racket: every entry into the
  submission runs under an `exit-handler` that raises. Octave:
  `ck_load_student` shadows the `exit` and `quit` builtins with command-line
  functions that raise when the caller is the submission (its top-level code
  while it loads, or a function it defined), on the native runner only; the
  browser wrapper's masks are already in force there.
- **C++ and Java keep the sentinel.** Every verdict in the runtime prints
  `CK_SENTINEL` first, and the wrapper refuses a run without it, so a plain
  `exit(0)` is an error. A submission that prints the sentinel line itself and
  exits 0 still reads as a pass (`docs/java-support.md`, `docs/cpp-support.md`).

**Moved to phase 3: grader-only files.** They stay readable to every test,
because a support file has no link to the tests that use it. Hiding them in
phase 2 would need that link, which is an authoring change. Phase 3 moves the
submission out of the test's directory, which closes this without one (decided
with the maintainer on 2026-11-05).

### Phase 3: a separate process for the submission (#2242)

The direction, not a decision: the submission runs in a child process, in a
second sandbox that shows only the submission files, and the test calls it
through a small message protocol. The verdict then comes from a process that
the submission cannot reach. It must also leave the grader-only files out of
the submission's view, which phase 2 did not do. The open questions are in
#2242. Stop and discuss before work starts.
