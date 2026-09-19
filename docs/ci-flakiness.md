# CI flakiness — state of knowledge (2026-07-02, last extended 2026-09-16)

Handoff document for the flakiness work. Families 1–3 are the original
2026-07-02 body; **Family 4 (2026-08-05) and Family 5 (2026-08-09) were added
later**, so the header date is where this started, not where it ends. Check
the newest families first — they are the ones still open.

Family 5 was rewritten on 2026-09-16 against a 213-run population rather than
a single log tail. Two of the three tells it used to carry turned out to be
artifacts of Swift Testing's reporting, so if you are working from a copy of
this file older than that date, re-read that entry before you conclude
anything from a per-test duration.

The first snapshot (earlier on
2026-07-02) was written while landing PRs #1138–#1142; the headline then:
**on an afternoon of loaded runners, an average PR had roughly a coin-flip
chance of at least one flaky-job failure per full CI run**, and the only
re-kick available to a bot (a new commit SHA) re-rolled *every* die at once.

This revision records the root cause and fix for Family 1 (the biggest
term), the containment shipped for Families 2–3, and the rerun ergonomics.

The four runs of PR #1138 remain the cleanest dataset because the tree was
**byte-identical across all four** (empty-commit re-kicks):

| Run | Head | Failing job | Failure shape |
|-----|------|-------------|---------------|
| 1 | `39985db` | `grading-probe (webkit)` | `hangs=1/12` — one grading iteration hung; iterations 10–12 passed (run 28586988643) |
| 2 | `d1f71d7` | `worker-tests` | `stdoutIsCaptured()` expectation failed **after 60.313 s** (run 28588059980) |
| 3 | `a8c8670` | `smoke (webkit)` → `editor-smoke-gate` | selftest: `post-idle execute passed? 0 (want 1)` — the exec-hang class (run 28588705591) |
| 4 | `38a5a60` | `worker-tests` | suite entered `WorkerTests` and hung until the 20-minute `timeout-minutes` kill (`cancelled`, run 28589351648) |

Three distinct flake families, none related to the diff (JS-only; each
failing job passed on other runs of the same tree).

---

## Family 1 — `WorkerTests.stdoutIsCaptured()` stall (issue #1139) — ROOT-CAUSED & FIXED

**Root cause.** A fork-safety bug in the worker's Linux script launcher
(`Sources/Worker/ScriptRunner.swift`, `executeLinuxScriptProcess`) — i.e. in
the **production grading path**, merely *exercised* by the tests. The forked
child called `setenv()` in a loop and bridged Swift Strings
(`chdir(workDir.path)`, Dictionary iteration) between `fork()` and `execvp`.
`fork()` in a multithreaded process snapshots glibc's locks (the environ
lock, malloc arenas) in whatever state other threads held them, with **no
thread left in the child to release them** — so if any thread held one of
those locks at the fork instant, the child deadlocked before exec. The
worker/test process is exactly that multithreaded (Swift concurrency pool,
Dispatch pipe readers, Swift Testing's parallel scheduler, several tests
that legitimately mutate env under `withEnvLock`), and the probability of a
collision scales with runner load — matching the observed load correlation.

Historical note: the Linux path originally built envp in the parent and
`execvpe`'d (CHANGELOG, v0.4.x env-passthrough work; the stale comment in
`SandboxedScriptRunner.swift` still said so). A later refactor regressed it
to setenv-in-child + `execvp`.

**Why the two observed shapes both follow:**

- *60 s expectation failure* — child deadlocks **after** `setsid()` (e.g.
  in the setenv loop). The parent's deadline fires at the script time limit
  (the test passed 60 s), the group-kill lands, the child is reaped with no
  output: `stdoutIsCaptured()` fails at ~60.3 s with empty stdout, and
  `runScriptRobustly`'s launch-flake retry correctly declines to mask it
  (`timedOut == true`).
- *20-minute job wedge* — child deadlocks **before** `setsid()` (e.g. in
  the `chdir` String bridging). `kill(-pid, …)` targets a process group
  that does not exist (ESRCH), both kill stages miss, and the *unbounded
  blocking* `waitpid(pid, &status, 0)` that followed pinned the wait thread
  forever; the test never completed and the job burned to its
  `timeout-minutes` kill.

**Reproduction (2026-07-02, this container, 4 cores).** A standalone
`swiftc` harness embedding the old vs. new child logic, with 3 threads
hammering setenv/getenv/unsetenv and 2 threads churning malloc while 4
threads fork+exec `/bin/sh -c 'echo hello world'` in a loop:

| Child logic | Iterations | Deadlocks |
|-------------|-----------|-----------|
| old (setenv/String-bridging in child) | 200 | **8 (4 %)** |
| fixed (async-signal-safe only) | 3000 | **0** |

**The fix (same PR as this doc revision):**

1. **Materialize everything pre-fork.** argv, envp (`KEY=VALUE` C-string
   vector), the workdir path, and the four raw pipe descriptors are built
   before `fork()`; the child calls only async-signal-safe functions
   (`setsid`/`close`/`dup2`/`chdir`/`sigprocmask`/`execve`/`_exit`).
2. **`setsid()` first** in the child, so the parent's timeout group-kill can
   always reach it no matter where a later step fails.
3. **Bounded post-kill reap** in `linuxWaitForChild` — SIGTERM/SIGKILL go to
   both the group and the pid, and the final reap is a WNOHANG poll with a
   5 s cap, never an unbounded blocking `waitpid`.
4. **`FD_CLOEXEC` on capture pipes** (Foundation's `Pipe` does not set it —
   verified on Swift 6.3/glibc 2.39): a concurrently spawned subprocess can
   no longer inherit a duplicate of the write end across its exec and starve
   the read side of EOF.
5. **Bounded final drain** (`poll` + `read` with a 2 s grace) replacing the
   blocking `readDataToEndOfFile()` that could pin a cooperative-pool thread.

**Security side-fix.** The old child applied the allowlisted env *on top of
the inherited full parent environment* — so on Linux (production!),
non-allowlisted worker env vars, including the shape `RUNNER_SHARED_SECRET`
arrives in, leaked into every student script, silently defeating the
allowlist in `mergedScriptEnvironment`. `execve` with the parent-built envp
replaces the environment outright (matching macOS `proc.environment`
semantics). Regression test: `scriptDoesNotInheritNonAllowlistedParentEnv`.

**Residual hygiene.** Subprocess-spawning WorkerTests suites now carry
`.timeLimit(.minutes(3))` so any future stall fails as a *named test* in
3 minutes instead of a silent 20-minute job burn. (Job-level
`timeout-minutes: 20` stays — it is sized for the cache-miss path where the
test job compiles from scratch.)

**Superseded (2026-08).** The hand-written `fork()`/`execve()`/`waitpid()`
launcher this section describes no longer exists. Every worker subprocess now
goes through `executeScriptLaunch` (`Sources/Worker/ScriptExecution.swift`),
built on `swift-subprocess`, which spawns without the fork-in-a-multithreaded-
process hazard that caused all of this — so points 1–3 above are now the
library's problem rather than ours, and the separate macOS `Process` path is
gone with them. Points 4 and 5 survive in `BoundedPipeRead.swift`, still used
by the capability probes and the MIME detector, which do build pipes by hand.
The analysis is kept because it explains constraints the replacement still has
to honour: session isolation before anything else can fail, a group-wide kill
rather than a per-pid one, no unbounded wait anywhere on a cooperative-pool
thread, and an environment that *replaces* rather than augments the parent's.

## Family 2 — webkit grading hang (`grading-probe (webkit)`, `hangs=N/12`) — CONTAINED, root cause open; the result-POST 500 that shares its counter is CLOSED

**Symptom.** The grading-hang probe (`grading-hang-probe.yml`) boots the
real server + notebook page 12 times per engine and counts grading hangs;
webkit intermittently reports `hangs=1/12`. Chromium passes 12/12 in the
same runs. Failures observed on unrelated branches 2026-06-26 (×3) and
2026-07-02 — a low, persistent background rate that predates that week.

**Context.** The probe *exists* to monitor a real historical bug — see
`docs/archive/exec-hang-investigation.md` and the boot-funnel telemetry work. The
hang still exists at low frequency on webkit under CI load.

**Gate policy (decided & shipped).** Chromium: hard zero everywhere.
Webkit: `hangs<=1/12` tolerated on `pull_request` runs with a loud
`::warning` annotation; `workflow_dispatch`/scheduled runs keep the hard
zero, so the probe remains the regression guard a real fix must turn green
and the ambient rate stays measured rather than silently absorbed.

**First chromium sighting (2026-08-04, PR #1261, run 30867456697).**
`grading-probe (chromium)` reported `hangs=1/12` while
`grading-probe (webkit)` passed in the same run — the inverse of the
pattern above, and the first time chromium has shown this. It did not
reproduce: a rerun of the same commit passed 12/12 on both engines. The
PR's diff could not reach the grading path (its only notebook.js change
sits inside `if (saveAssignmentBtn)`, a staff-only button the probe's
student session never renders), so this reads as the same ambient rate
rather than a regression.

Recorded because the sentence above — chromium passes 12/12 — is what
makes a chromium hang look like a real regression to the next person who
hits one. It is rarer than webkit's, not impossible. The gate policy is
deliberately unchanged: chromium stays at hard zero, so a second sighting
is loud rather than absorbed. If it recurs, that is the signal to treat
chromium as in-family and go after the shared root cause.

**Second chromium sighting (2026-08-05, PR #1274, run 31041617233) — and it
is NOT the exec-hang.** The paragraph above asked for a second sighting to be
treated as in-family. Read the breadcrumbs before doing that: this one is a
different failure wearing the same label.

```
grading_start -> runtime_loaded [123] -> setup_unpacked [143]
-> suite_started [172;tests=1] -> grading_init_start [173]
-> pyodide_loaded [1584] -> env_configured [1612] -> grading_init_done [1612]
-> suite_done [1621;n=1] -> result_posting [1622]
-> submit_failed [2249; Failed to submit results: 500 ...]
```

Grading **completed**, in 1.6 s, with its one test graded (`suite_done n=1`).
What failed was the POST to `/api/v1/submissions/browser-result`, which returned
HTTP 500; the page then sat for the probe's full 300 s submit budget and the
harness scored it a hang. Family 2 is the opposite shape — execution never
finishing. Same counter, different bug.

The PR's diff could not reach the failing endpoint: it touches one Swift file
(`BrowserRunnerRoutes.swift`, the *seed* endpoint) and not
`BrowserResultRoutes.swift`, and the same probe passed 12/12 on chromium twice
on the same branch. A re-run passed.

Two things follow:

1. **`hangs=N/12` is a misnomer** — the counter is "iterations that did not
   render a result", which includes a server-side 500 after a perfectly healthy
   grade. Anyone triaging one of these should read the breadcrumb trail first
   and only reach for `docs/archive/exec-hang-investigation.md` if the trail
   stops *before* `suite_done`.
2. **The chromium hard-zero gate stays**, but this sighting should not be
   counted as evidence that chromium has joined the exec-hang family. It is
   evidence of a separate, rarer, server-side intermittent on the result POST,
   which nobody has looked at yet.

**Third sighting (2026-08-10, PR #1326, run 31392463877) — same result-POST
500, and the reason nobody has looked at it is now fixed.** Identical shape to
the second: `suite_done [n=1]` at 2,102 ms, `result_posting`, then
`submit_failed [2,462; … 500 …]`, iteration 10 of 12, the other eleven green.
The PR's diff reaches neither `BrowserResultRoutes.swift` nor any server path —
it changes a browser inputs-filename lookup, two test files, and a shell
generator.

What this sighting adds is why the previous two produced no diagnosis.
`run-smoke.sh` dumps `tail -40` of the server log on failure, added
specifically so "a server-side 500 (e.g. a SQLite `database is locked`) is
visible in CI". It cannot be, on this failure: after the submit 500s the page
keeps polling `GET /api/v1/submissions/:id` for the probe's full 300 s budget,
so the last 40 lines are several hundred INFO polls and the 500's own line has
scrolled away. Every triage of this family has been reasoning from breadcrumbs
because the evidence was being discarded at the moment it was collected. The
script now greps the whole log for error-level lines *before* printing the
tail, so the next sighting names its cause.

**CLOSED (2026-08-10), without needing that log line.** The hypothesis above
was right about the location and wrong about the mechanism, and the mechanism is
why it took three sightings.

The window is exact. `suite_done` was reached, the POST 500'd, and the page then
polled `GET /api/v1/submissions/:id` and got **200** for its full budget — so
the SUBMISSION row existed and the RESULT did not. Something between the two
threw. In the probe's configuration exactly one thing there could:
`awardFirstToSubmitRecords`, an unguarded read-then-write. Its neighbour
`flagResultForBrightSpaceSync` only reads, and returns immediately when no
BrightSpace credentials are configured — the smoke's case.

**Why it threw at all is the part that was not obvious.** sqlite-nio installs a
busy handler that returns 1 forever (`SQLiteConnection.open`), so ordinary lock
contention never surfaces as an error — which is why "set a `busy_timeout`" is
the wrong fix, and why reading the handler for a missing timeout finds nothing.
What a busy handler cannot cover is `SQLITE_BUSY_SNAPSHOT`: a WAL read snapshot
made stale by another connection's commit. SQLite returns it IMMEDIATELY,
bypassing the handler, because waiting cannot help — only restarting the
transaction can. Every badge helper is read-then-write, the exact shape that
hits it, and the page's own result polling supplies the concurrent commits.

The fix is two changes, and the second is the one that matters:

1. The Pathfinder award moved BELOW the result save. It was the only reason the
   window was lossy rather than merely noisy.
2. Every side effect after the result now runs through a `bestEffort` wrapper —
   `withTransientDatabaseLockRetry` first, then log and continue. A class badge
   is worth an ordinary amount; a student's grade is not worth losing for one.

`BrowserResultSideEffectOrderTests` pins both, and reproduces the original
failure when the order is reinstated. The `run-smoke.sh` error-line change from
the same PR stays useful for the next intermittent, which will not be this one.

**Root cause** of Family 2 remains the exec-hang investigation's to close —
continue from the probe's `grading breadcrumbs:` per-phase timings on an
iteration whose trail stops before `suite_done`.

**Status revision (2026-08-22, covers Families 2 AND 3): the ambient rate
collapsed with the Pyodide→xeus migration, and the archived trail is now
historical.** Both families' root-cause work was scoped against the Pyodide
editor, and every live mechanism it identified was pyodide-kernel-driver
code: the premature idle (`kernelInfoRequest` answering without awaiting
`this.ready`), the ~13–17 s WebKit `initialize()` tail behind it, and the
chdir/DriveFS hang before either. None of that code ships since the 0.5
series moved the editor (and later both graders) onto xeus — so a NEW hang
cannot be that bug, and `docs/archive/exec-hang-investigation.md` is the old
era's record, not a trail to continue.

Measured, both halves:

- **CI.** The scheduled hard-zero `editor-smoke` runs on `main` — the legs
  with no webkit tolerance — are 30/30 green, 2026-07-24 → 2026-08-22.
  `grading-hang-probe` shows no ambient failure in the same window (its one
  red, 2026-08-10, was the result-POST 500 closed above). The #1178 weekly
  tallies report at most one tolerated-flake warning per week across the
  last four.
- **Production** (`get_browser_diagnostics`, 720 h window read 2026-08-22,
  which straddles the migration near its midpoint at comparable boot volume
  per half): `exec_hang` 35 → 1 (~4.1 % → **~0.14 %** of boots — the July
  reading of ~4 % held to the end of the old era), `boot_stalled` 32 → 2,
  `kernel_unknown` 44 → 8, `recover_failed` 1 → 0, and the recent half's
  submit funnel lossless (62/62 `grading_start` → `result_posted`).
  Confound stated plainly: the era boundary coincides with the term winding
  down, so lighter and calmer usage shares credit with the substrate — but
  the mechanisms above are gone from the shipped code regardless of the
  weighting.

What this changes and what it does not. The webkit gate tolerances stay:
the residual is small but not zero, and tightening buys a roughly weekly
blocked merge for no new information. The next lever for the residue is not
the archive but the probe's five-way classification (`deadlock` /
`bootStall` / `dialogSteal` / `lostDispatch` / `webkitWasmCrash`) plus
issue #1049's enriched beacons — that boot-failure class also fell an order
of magnitude across the boundary and keeps its old-Safari hypothesis for
what remains. The #1245 per-boot rejection was re-measured the same day
(~1.0 → ~0.29 per boot across the boundary; the ratio can no longer
attribute the residual, so the issue's stack-frame instrumentation is the
only path left — details on the issue).

## Family 3 — webkit editor smoke, post-idle execute (`smoke (webkit)`) — CONTAINED, same root cause as Family 2

**Symptom.** The editor-smoke selftest's post-idle probe fails:
`post-idle execute passed? 0 (want 1)` — kernel never runs the expression.
~1 failure in 25 gate runs, and `smoke` feeds `editor-smoke-gate`, the
**required** check — so this family, though rarest, hard-blocked merges.

**Containment (shipped).** The webkit legs of the `smoke` job (selftest and
notebook-page e2e) get exactly one retry, logged with a `::warning` so the
flake rate stays visible in annotations. Chromium legs stay strict — a
chromium failure is treated as real, first time.

**Status revision (2026-08-22):** see the block at the end of Family 2 —
the shared root-cause work is overtaken by the Pyodide→xeus migration, the
scheduled hard-zero legs have run a month green, and the retry tolerance
stays for the small non-zero residue.

---

## Family 4 — `worker-tests` SIGABRT via the wedge watchdog (URLSession cancel deadlock) — MITIGATED first-party; root cause still upstream

**Symptom.** `worker-tests` fails (not cancelled) after ~5 minutes with
`exited with unexpected signal code 6`. The crashing thread is
`WedgeWatchdog.abortWedgedProcess` at `WedgeWatchdog.swift:120` — i.e. the
watchdog working as designed, aborting a wedged process so CI gets a thread
dump instead of a silent job kill. The wedge itself is elsewhere in the dump.

**Root cause (from the dumps).** A lock-order inversion between Swift
Concurrency's per-task status-record lock and a Dispatch queue inside
swift-corelibs-foundation's `URLSession`, on Linux:

- one thread is in `swift_asyncLet_finish` → `swift_task_cancel` →
  `withStatusRecordLock` → `URLSession.CancelState.cancel()` →
  `DispatchQueue.sync` — holding the status-record lock, waiting on the queue;
- another is in the multi-handle completing a transfer →
  `URLSession.download(for:delegate:)`'s continuation →
  `flagAsAndEnqueueOnExecutor` → `withStatusRecordLock` — holding/serving that
  queue, waiting on the lock.

Neither can proceed, and the cooperative pool fills behind them. Every frame
is in `libFoundationNetworking` / `libswift_Concurrency` / `libdispatch`;
the only first-party frame is the watchdog reporting it.

**Trigger.** Cancelling an in-flight `URLSession` download. The worker's job
setup runs `async let submissionDownload` alongside the test-setup fetch
(`RunnerDaemon+JobProcessing.swift`), so when one leg fails — which several
tests deliberately induce with 404s — `swift_asyncLet_finish` cancels the
other mid-transfer and can hit the inversion. Whether the racing transfer is
completing (`completeTask`) or failing (`urlProtocol(task:didFailWithError:)`)
varies between dumps; the inversion is the same.

**Evidence it is not PR-local.** Observed on `main` at commit `32922738`
(run 31020720996, job 92360716560, 2026-08-05 15:53) and on an unrelated
feature branch (run 31029658951, job 92390500832) with identical stacks.
`main` was otherwise green on 14 of its 15 preceding runs, so the rate is
low but real.

**Diagnosis confirmed, and sharpened (2026-08-09, Swift 6.3, this container).**
A standalone `swiftc` harness reproduces it on demand, and `gdb -p` on the
wedged process shows exactly the two stacks above. Two refinements the original
entry did not state, both load-bearing:

- The two threads are contending over **the same task's** status-record lock.
  Foundation's `URLSession` has one `workQueue` per session, so the canceller
  (`swift_task_cancel` → `withStatusRecordLock` → `CancelState.cancel` →
  `URLSessionTask.cancel` → `DispatchQueue.sync`) blocks on a queue that the
  multi-handle is already occupying inside `completeTask` →
  `urlProtocolDidFinishLoading` → `CheckedContinuation.resume` →
  `flagAsAndEnqueueOnExecutor` → `withStatusRecordLock`, waiting for the lock
  the canceller holds. Same task, opposite order — a plain AB-BA.
- It is therefore **not specific to `async let`**. Any cancellation of a task
  suspended in `URLSession.download` that is completing at that instant can hit
  it. `async let` was simply the site that did it on a schedule.

**Fix shipped (first-party mitigation only).** The prepare phase's two fetches
now both report a `Result` and are **both always awaited**
(`fetchJobArtifacts` in `RunnerDaemon+JobProcessing.swift`), so one leg's
failure can no longer leave the scope with the other still transferring. The
submission download stays a *structured child* of the job task, so cancelling
the daemon still tears an in-flight transfer down — the #1233 property is
untouched, and `cancellingTheDaemonStopsTheInFlightSubmissionDownload` pins it
end to end (the server writes an `aborted` breadcrumb, which is the only way to
tell a cancelled transfer from an abandoned one from outside `URLSession`).
`testSetupFailureDoesNotCancelTheInFlightSubmissionDownload` pins the new
property and fails on the old code rather than merely being slower on it.

Sequencing the two fetches was the other candidate and was rejected: it removes
the same trigger but serialises a network fetch against a network-or-copy on
every job, and it does not remove any cancellation site the reconciliation
leaves behind — so it costs throughput for no additional coverage.

**Measured.** In-repo harness: 300 jobs against an always-404 server, 4 slots.
Before: 4 wedges in 8 runs (a wedge starves the cooperative pool so completely
that the harness's own progress poll stops running). After: 0 wedges in 16 runs
/ 4,800 jobs. Standalone harness, same shape without the repo: 10 wedges in 10
runs before, 0 in 13 runs / 88,000 iterations after.

**What is NOT fixed.** The upstream bug is untouched, and four sites still
cancel an in-flight `URLSession` transfer. Three are the deliberate ones
cancellation is *for*: cancelling the job task (which propagates into the
submission download), `TestSetupCache.detachWaiter` cancelling the shared
populate task once its last waiter leaves (#1233), and
`withThrowingDiscardingTaskGroup` in `daemon.run()` cancelling the sibling
worker loops when one takes a terminal poll error. The fourth is incidental and
was left alone deliberately: `process(_:)`'s `defer` cancels the per-job
heartbeat task, which may be mid-POST. That loop sleeps 30 s between ~1 ms
requests, so the window is ~10⁻³ of a job rather than every failed one, and
closing it means letting the loop finish cooperatively (up to 30 s of lingering
task per job) — worth doing only if this family reappears.

**Handling if it reappears.** Re-run the failed job — `/rerun-failed` on the
PR, or `rerun-failed-jobs`. Before blaming a red `worker-tests` on the diff in
front of you, check the dump for `WedgeWatchdog.abortWedgedProcess` plus a
`CancelState.cancel` / `withStatusRecordLock` pair; that combination is this
family, not the change under test.

### It reappeared (2026-09-15), at the site this entry predicted

`Mutation testing (weekly)` run 34959089994, shard 0 of 12. The shard aborted
at the watchdog's five-minute mark, in the **unmutated baseline**. It therefore
measured nothing, and the workflow went red while the other eleven shards were
green.

The dump is this family. The canceller is the second of the three deliberate
sites listed above: `TestSetupCache.detachWaiter`
(`TestSetupCache.swift:318`, `population.task.cancel()`). It cancelled a
populate task that was inside `RunnerDaemon.download`. The other half of the
cycle was `URLSession.download(for:)` resuming its continuation on the session
work queue. No change under test was involved. `main` was green on both sides.

### What was tried, measured, and NOT shipped

The obvious fix is to stop using Foundation's async `data(for:)` and
`download(for:)`, and to drive the completion-handler API instead. Record why
it works, because the first guess is wrong:

- The async API resumes its continuation **on the session work queue**. That is
  what puts `withStatusRecordLock` on the queue side of the cycle. A
  completion-handler wrapper resumes from the **delegate queue**, so the work
  queue never waits for the status-record lock. The cycle does not form.
- The hazard is therefore not "blocking inside `swift_task_cancel`". A control
  that cancelled synchronously from the cancellation handler also never wedged:
  16 of 16 runs clean, against 6 of 6 wedged for the async API. Harness: 16 to
  32 concurrent transfers, each cancelled at the moment it completes.

**It was reverted, because it replaces the deadlock with a crash.**
`URLSessionTask.cancel()` in swift-corelibs-foundation schedules work that
later calls `URLSession.behaviour(for:)`. If the transfer completed and left
the session's task registry first, that is a `fatalError`: "Trying to access a
behaviour for a task that in not in the registry" (`TaskRegistry.swift:118`).
It is a SIGILL, not a catchable error. With the wrapper, the logic-tier suite
(`--skip APITests`) crashed in **7 of 12** runs. `main` was clean in 12 of 12.

A `finished` flag set from the completion handler does not close the window. A
`task.state` guard does not close it either. Neither can: the protection
corelibs uses for that race is the `workQueue.sync` inside `cancel()`, and that
is the call that deadlocks. **The deadlock and the fatalError are two halves of
one upstream bug.** A later attempt must answer the crash, not only the wedge.

The remaining options are all behavioural, and each one costs something:

1. Re-run the shard and accept the rate. This is what the entry above says.
2. Do not cancel in `detachWaiter`. A cancelled population then completes its
   download instead of aborting it. This wastes one test-setup transfer, and it
   weakens the #1233 property that existing tests assert.
3. Shield the download from task cancellation in the primitive. This has the
   same cost as option 2 at all three sites. A cancelled daemon also stays
   alive until the transfer ends, or until its 600 s resource timeout.

### Decision (2026-09-15): option 1

**Accept the rate. Do not change the runner to dodge this.** Options 2 and 3
both weaken a property that was pinned on purpose, in order to work around a
bug in a dependency that a later Foundation can fix. The measured rate does not
justify that: one shard in twelve, once, against a weekly sweep that already
reports per-shard and files from the shards that did run.

So the handling is the paragraph above this section, unchanged: **re-run the
shard.** A sweep that loses one shard to this is not a failed sweep. Read the
other eleven and re-run the twelfth.

Reopen the decision if any of these changes:

- the rate rises above roughly one shard per sweep, or it starts hitting
  `worker-tests` on ordinary PRs rather than only the mutation baseline;
- it reaches a runner in production, where the wedge is a stuck job rather
  than a red CI job;
- swift-corelibs-foundation fixes either half, at which point the fix is to
  take the new Foundation, not to write either workaround.

---

## Family 5 — `api-tests` killed at its ceiling during a throughput collapse — 7 occurrences (2026-08-09 → 2026-09-15); COST ROOT-CAUSED & FIXED, COLLAPSE NARROWED but open

**Symptom.** `api-tests` reports **`cancelled`** and `swift-tests-gate` fails
with `jobs not successful: api-tests`. It reads exactly like the Family 1 /
#1233 wedge — same conclusion string, same burn to the ceiling — and it is
**not one**. The job is still finishing tests at the moment of the kill.

Everything below the next heading is new work (2026-09-16). The entry used to
say "observed once, root cause open". It was observed seven times, the
population is now measured rather than sampled, and two of the three tells it
recorded are artifacts of the test harness rather than evidence of anything.

---

### Correction: two of this entry's three original tells are not evidence

This matters more than the incidents, because both were used to diagnose both
incidents by hand.

**Tell 2 — "three unrelated suites reported near-identical totals" — is true
of every run, healthy or not.** So is **tell 3, the inflated per-test
durations** added from incident 2 (`slugify_handlesHyphensAndSlashes()`, a
string function, "passed after 106.949 seconds").

Swift Testing starts the clock for a test when the test is **scheduled**, not
when it gets a parallelization slot. `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4`
gates the body, not the timer, so a test's reported duration is mostly the
queue it waited in. Reproduced directly on Swift 6.3 with a 64-test package
whose every body is a 400 ms sleep:

```
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4 swift test
  peak bodies executing concurrently: 4      <- the cap DOES work
  ✔ Test t51() passed after 6.408 seconds.   <- for a 400 ms body
  ✔ Test run with 64 tests in 1 suite passed after 6.411 seconds.
```

The last test to finish always reports approximately the whole run. Every
suite therefore always ends at approximately the run's total. In the real CI
logs:

| `api-tests` run | wall clock | tests | reported per-test median | max | fastest test |
|---|---|---|---|---|---|
| job 104001398957 (healthy) | 328 s | 3,131 | **80.4 s** | 205.1 s | 0.325 s |
| job 103822024167 (3.8× slow) | 1,249 s | 3,115 | 199.8 s | 776.4 s | 0.307 s |
| job 104630832798 (healthy) | 347 s | 3,219 | 89.3 s | 221.4 s | — |

A healthy run's *median* test reports 80 seconds, and its slowest reports
205. Incident 2's 107-second `slugify` is below the maximum of a **healthy**
run a third the length — so it is not evidence of anything, let alone of a
5x event.

There is a second, independent reason that example was misread.
`slugify_handlesHyphensAndSlashes()` is not a pure string function's cost.
`VanityURLRoutesTests` is a `final class` suite, so Swift Testing builds a new
instance per test, and its `init` calls `makeTestApp` — a whole Vapor
application with 60 migrations — which `withApp` then tears down. The
assertion is one string comparison; the test is an application boot. That is
true of most of this target, and it is the same fact that finding 5 below
turns into the root cause of the cost.

Two further facts fall out of the same logs and are used below: 2,172 of 3,040
tests were "started" concurrently (the log line precedes the slot, so this is
not 2,172 live Vapor apps — a 64-test probe at width 4 shows exactly 4 bodies
executing at once), and **the fastest test costs the same on a slow run as on
a fast one (0.307 s vs 0.325 s)** — so nothing about the machine's
per-operation speed changes. What changes is throughput.

**Tell 1 — "were tests still completing at the tail" — survives.** It is the
only one of the three that distinguishes this from a wedge, and it is still
the first thing to check.

---

### The occurrences

Seven, not one. Five of them are on `main`, where the concurrency group never
cancels a run, so `cancelled` there can only be the job's own
`timeout-minutes`.

| date | ref | `Run APITests` | conclusion |
|---|---|---|---|
| 2026-08-09 | PR #1308 `07efab8` attempt 1 | 1107 s | `cancelled` (20-min ceiling) |
| 2026-08-18 20:07 | `main`, job 95852055877 | 1386 s | `cancelled` |
| 2026-08-19 19:56 | `main`, job 96206596827 | 1373 s | `cancelled` |
| 2026-08-19 20:36 | `main`, job 96218450897 | 1382 s | `cancelled` |
| 2026-08-20 16:53 | `main`, job 96508206917 | 1389 s | `cancelled` |
| 2026-08-25 20:43 | `main`, job 97961643124 | 1398 s | `cancelled` |
| 2026-09-15 | PR #1529 `f8ffb34` | ~1500 s (job) | `cancelled` (25-min ceiling) |

**Incident 1 (2026-08-09, PR #1308, `07efab8`).** Two attempts of the same job
on the same commit, ~25 minutes apart: attempt 1 `Run APITests` **1107 s,
killed at the ceiling**; attempt 2 **216 s, success**. No code changed.
Different runners (`1000033632` vs `1000033636`), setup ~93 s both. 216 s was
below the then-median, so attempt 1 was the outlier.

**Incident 2 (2026-09-15, PR #1529, `f8ffb34`).** `api-tests` `cancelled`
after ~25 minutes (22:49:46 → 23:14:50) against the *raised* ceiling;
`swift-tests-gate` failed with it. **966 tests completed**, the last at
23:14:44 — three seconds before the cancel. Completions per minute at the
tail: 23:09→171, 23:10→125, 23:11→81, 23:12→83, 23:13→40, 23:14→35. Progress
the whole way, so not a wedge. `api-tests-postgres` **passed on the same
commit in 11 minutes**; `rerun-failed-jobs` passed in **7 m 43 s**; the diff
contained **zero Swift** (two workflow YAMLs, dependabot.yml, a doc, a
changelog fragment, a standalone Python script); `api-tests` on PR #1530 the
same night took **7 m 25 s**. The "inflated durations" also recorded for this
incident are the harness artifact corrected above, and are not evidence.

---

### The population, and what it excludes

`swift-tests.yml` on `main`, **213 completed runs**, 2026-08-10 → 2026-09-16,
per-step durations from the Actions API. Every job in a run is a DIFFERENT
hosted runner, so this is five independent samples of the fleet per run.

| lane | step median | p90 | p99 | max | max/median | runs ≥2× median |
|---|---|---|---|---|---|---|
| `build` | 597 s | 675 s | 697 s | 704 s | **1.18×** | **0 / 213 (0.0 %)** |
| `api-tests` | 291 s | 599 s | 1386 s | 1398 s | 4.80× | **23 / 213 (10.8 %)** |
| `api-tests-postgres` | 391 s | 541 s | 1066 s | 1327 s | 3.39× | 8 / 213 (3.8 %) |
| `worker-tests` | 20 s | 22 s | 30 s | 607 s | 30.4× | 1 / 213 (0.5 %) |
| `core-tests` | 14 s | 15 s | 19 s | 391 s | 27.9× | 1 / 213 (0.5 %) |

`worker-tests` and `core-tests` share their single excursion: run
31560614917 (2026-08-12 03:36) was slow in all four test lanes at once, the
only run-wide event in the window. Every other excursion is confined to ONE
lane while the other four in the same run sit at 0.9–1.1× their medians.

**`build` is the control, and it settles the ambient-slowness hypothesis.** It
is a ten-minute, CPU-saturating compile on the same fleet, same image family,
same hour — longer exposure than `api-tests` and more sensitive to lost CPU,
not less. Across 213 runs its worst run is 1.18× its median and it has never
been 2× anything. A fleet that varies by 3–5× would show up there first.

Two more controls, inside the slow jobs themselves. Comparing the 23 slow
`api-tests` jobs against the 176 fast ones, step by step:

| step | fast median | slow median | ratio |
|---|---|---|---|
| `Initialize containers` | 66 s | 77 s | 1.17 |
| `actions/checkout` | 9 s | 10 s | 1.11 |
| `Restore build artifacts` (multi-GB untar) | 23 s | **21 s** | **0.91** |
| `Run APITests` | 285 s | 920 s | **3.23** |

On the very machines that then ran the tests 3.2× slow, a multi-gigabyte
archive extracted at full speed, minutes earlier. Bulk disk throughput and
network were fine. The degradation is specific to the test step.

---

### What is now ESTABLISHED

1. **It is not ambient hosted-runner slowness.** `build` — longer, CPU-bound,
   same fleet — has zero excursions in 213 runs. The APITests lanes have 31
   between them.
2. **It is not a slower machine.** The fastest test in a 1,249 s run costs
   0.307 s against 0.325 s in a 328 s run. Per-operation speed is unchanged;
   only throughput falls.
3. **It is not the machine's disk throughput or its network.** The cache
   restore on the slow jobs is, if anything, marginally faster.
4. **`api-tests` is I/O-STALL-bound, not CPU-bound, even on healthy
   hardware.** Measured locally at CI's parallelization width with the new
   recorder (below), on a 4-core NVMe box: **PSI `io_full` 20–27 % of wall
   clock** — a fifth to a quarter of the run with EVERY task on the machine
   blocked on disk — against `cpu_full` 0.0 % and `mem_full` 0.0 %.
5. **The stall comes from the per-test temp state.** The suite builds ~3,200
   Vapor test applications per run — one per test body in a class suite, since
   Swift Testing makes a new instance per test and `init` calls `makeTestApp`.
   Each application creates a five-directory temp tree AND, because sqlite-kit
   backs a `.memory` database with a real on-disk temp file
   (`sqlite-kit_memorydb-*`, which `tearDownTestApp` already knows about), a
   real SQLite file, against which `autoMigrate` then runs **60 migrations**.
   The database is the transactional half and therefore the likely dominant
   one — tens of thousands of small fsyncs per run — but the measurement below
   moves the whole of `/tmp`, so the two halves are NOT separated here. If
   that distinction ever matters (e.g. for attack note 5), it needs its own
   experiment.
6. **Removing that I/O removes 42 % of the step.** Same machine, same build,
   same 3,2xx tests, `/tmp` on disk vs `/tmp` on tmpfs:

   | `/tmp` | run 1 | run 2 | PSI `io_full` |
   |---|---|---|---|
   | disk | 287.6 s | 274.9 s | 20–27 % |
   | tmpfs | 165.7 s | 162.1 s | **0.0–0.2 %** |

   Peak tmpfs occupancy across a full run: **4 MiB**.
7. **Two of this entry's three original tells are harness artifacts** — see
   the correction above. This is why the family needed an instrument and not
   another log tail.
8. **`WedgeWatchdog` cannot detect this, by design.** Its header says so:
   it measures silence, and a lane running at 4× cost keeps starting and
   finishing tests, which resets its clock continuously. Attack note 1 below
   used to claim the watchdog would settle this family's open question. It
   cannot, and that note is corrected.
9. **The 20 → 25 minute ceiling raise bought nothing net.** Under the old
   ceiling the step had ~1107 s of budget against a 236 s median: 4.69×. Under
   the new one it has ~1400 s against a 291 s median: 4.81×. Suite growth
   consumed the headroom as it arrived. The five `main` kills all sit at
   1373–1398 s — exactly the new budget — so the real multiplier on those runs
   is censored at ≥4.8× and is not known.

### What is still OPEN

**Why throughput collapses 3–5× on ~11 % of runs.** Ruled out above: the
fleet, CPU speed, bulk disk throughput, network. Not ruled out, in order of
how well they fit:

- **fsync latency variance.** Throughput and latency are different properties.
  A machine that untars gigabytes at full speed can still have 3–5× worse
  commit latency, and this workload is bound by commit latency rather than
  bandwidth (finding 4). This fits every control.
- **Something inside our own process** — the Swift Testing scheduler, the NIO
  event-loop group, or the SQLite connection pools — degrading under an
  unlucky ordering. The excursions are bimodal (ratios cluster near 1.0 or
  near 3–4.8, with little between), which reads more like a latch than like a
  continuum of machine speeds.
- **CPU steal from a co-tenant.** Poorly supported — `build` would show it —
  but it is the one cause nothing in this repository could fix, so it must be
  measured rather than argued away.
- **A subprocess storm.** The lead this entry used to lead with, kept but
  demoted: nothing measured supports it, and the recorder's process census is
  what would. Re-counted 2026-09-16 — **21 of 376 `Tests/APITests/` files both
  spawn `Process()` and name a real interpreter** (25 spawn a process at all;
  36 name an interpreter somewhere). The entry's earlier figure, 35 of 314
  files spawning and 29 naming an interpreter, no longer matches the tree: the
  target grew and the spawn sites were partly consolidated into helpers.

The recorder below reports all three directly. **Do not guess at this again
from a log tail; read the `[ci-pressure]` lines.**

---

### What shipped

**1. `StarvationRecorder` — the instrument this family never had.**
`Tests/TestSupport/StarvationRecorder.swift`, with `HostCounters`,
`HostCounters+Capture` and `PressureWindow` beside it. It runs on a dedicated
OS thread, like the wedge watchdog and for the same reason, and writes one
line to stderr every 30 seconds:

```
[ci-pressure] t=60s | win=30.0s cpu_some=20.0% cpu_full=0.0% io_some=26.8% io_full=21.4%
  mem_full=0.0% steal=0.0% iowait=20.1% busy=62.3% | self cpu=55.2% scopes=483.9/min thr=18
  procs=77 kids=0 rss=291.0MiB throttled=+0 cg_cpu_some=- | load=3.1 runq=4/130
  | run(60.0s) cpu_some=19.1% io_full=24.0% steal=0.0% self_cpu=53.3% scopes=491.9/min
[ci-pressure] HINT the machine was fully stalled on disk for 21.4% of this window.
  Throughput is bound by I/O latency, not CPU.
```

Each line carries both the last window and the cumulative totals since
arming, because **the failure being investigated ends in a kill** — the
process never runs an exit handler, so whatever the last line to reach the log
is, it must also be the summary. That is the design's load-bearing decision.

`scopes/min` is completed `WedgeWatchdog.track` scopes — in APITests, finished
test bodies. It is the throughput half: without it every pressure reading is
an unanchored number, and with it one line says both that throughput collapsed
and what the machine was doing while it did.

Reading it, in the order the hint rules fire:

| field | non-zero means |
|---|---|
| `steal` | the hypervisor gave this VM's CPU to another tenant. Nothing here can fix it. |
| `throttled` | the kernel stopped the container for exceeding its CPU quota. Ours. |
| `io_full` | the machine did NO work because every task was blocked on disk. |
| `mem_full` | the same, for memory reclaim. |
| `kids` ≫ CPUs | a subprocess storm — 21 APITests files spawn real interpreters. |
| `busy` high, `self cpu` low | something else in this VM is using the machine. |

A busy box doing our own work gets **no hint**: that is what a test suite is
for, it is true of every healthy run (measured: `busy` 69.8–90.9 %, `self cpu`
68.9–92.2 %), and a hint on every line of a green log is a hint nobody reads
on the one line that mattered.

**Arming is the watchdog's seam, deliberately.** The recorder has no arming
call of its own; it starts with `WedgeWatchdog`'s monitor, which APITests arms
at `withApp` and WorkerTests arms at its helper scopes. That reuses a seam
that is already guarded rather than adding a second one that could rot.
`StarvationRecorderTests.theWatchdogSeamArmsTheRecorder` keeps the borrowing
honest. No new environment variable (CLAUDE.md's standing rule);
`CHICKADEE_WORKERTESTS_STALL_SECONDS=0` still disables the watchdog's abort
and deliberately does NOT disable recording — a run debugged with the abort
off is exactly a run somebody wants numbers from.

**Seen to fire.** `StarvationRecorderTests` (18 tests) drives each of the six
verdict rules to its own sentence against synthesised counters, pins the two
cases that must stay SILENT (a healthy box, and a busy box doing our own
work), pins the arithmetic, parses captured `/proc` and cgroup text for both
cgroup layouts, and then takes two real samples around a real CPU burn and
asserts the recorder measured it. Beyond that, the lines quoted above are
from a full local `APITests` run: the instrument was watched diagnosing the
real defect, before that defect was fixed.

**2. The APITests lanes' `/tmp` is now a tmpfs.** `--tmpfs /tmp:rw,exec,size=2g`
on the `api-tests` and `api-tests-postgres` containers. `exec` is load-bearing
— Docker defaults `--tmpfs` to `noexec` and the suite writes generated scripts
into these directories and runs them.

What it buys: see the measured figures in "Where the lane landed" below —
this paragraph used to carry a prediction (an expected ~170 s median and a
4.8× → ~8.2× absorbable multiplier) and the real numbers have replaced it. It
is the first change here that works on the *mechanism* rather than the budget:
if the collapse is fsync latency, removing the fsyncs removes the exposure and
not merely the size of the bill.

### First CI measurements (2026-09-16, PR #1531)

Both lanes green on both heads, and the recorder's first real hosted-runner
artifact:

```
[ci-pressure] armed cpus=4 quota=none mem_avail=13.4GiB host_psi=yes cgroup_psi=yes interval=30s
[ci-pressure] t=60s | win=30.0s cpu_some=13.2% cpu_full=0.0% io_some=0.0% io_full=0.0%
  mem_full=0.0% steal=0.0% iowait=0.0% busy=91.8% | self cpu=91.2% scopes=430.0/min
  thr=22 procs=4 kids=0 rss=286.5MiB throttled=+0 cg_cpu_some=12.4% | load=4.6 runq=5/293
```

| lane | `193e4713` | `475d770f` | `c2be6d95` | `main` median (213 runs) |
|---|---|---|---|---|
| `api-tests` | 189 s | 230 s | 217 s | 291 s |
| `api-tests-postgres` | 382 s | — | 342 s | 391 s |

**These are three PR runs, not a population.** They accumulated while
iterating on this branch, and the table stops here deliberately: appending a
row per push is a regress, and the acceptance test is the `main` population,
not this table.

At n=3 the sqlite lane is **−25 % to −35 %**, and the honest statement is
"materially cheaper, somewhere in that band" rather than any single figure.
Quoting the best run of a lane whose run-to-run spread is the entire subject
of this entry would be the exact error the rest of the section is written to
prevent. What IS solid at n=3 is the mechanism rather than the magnitude:
`io_full` was 0.0 % in every window of every run, against 20–27 % on disk.

Four things this settles, two of them against what was written above.

1. **The tmpfs change works on the real runner.** `io_full` is **0.0 % in
   every window** of the sqlite lane on both runs, against 20–27 % locally on
   disk. The stall the change targets is gone; that part does not depend on
   how the two duration samples land. Both being below the local 42 % is the
   expected direction — the hosted runner's disk was never the local NVMe.
2. **The runner is a 4-CPU box with ~13.4 GiB available and NO CPU quota**,
   not the 2-core runner this document and several workflow comments still
   assume. GitHub's standard `ubuntu-latest` was upgraded. Nothing in the
   analysis above depends on the core count, but anything reasoning about
   "width 4 on 2 cores" is now reasoning about width 4 on 4 cores, which is a
   different tuning question. Stale "2-core" claims survive in
   `Tests/APITests/TestHelpers.swift`, `Tests/WorkerTests/Support/SubprocessThrottle.swift`
   and the `worker-tests` job comment; only the last is corrected here, to
   keep this change narrow.
3. **The postgres lane benefits much less, and the doc predicted too
   confidently that it would get "part of the win".** Its samples are 382 s
   and 342 s against a 391 s median — a small win at most. An earlier
   revision of this paragraph called it **no** win, on the strength of the
   382 s sample alone; the 342 s one does not support a firm null either, and
   asserting one from n=1 was the same error as quoting −35 % from n=1 two
   paragraphs up. Both are corrected; neither is settled.

   The recorder says why the lane is different, and that part does NOT rest
   on durations: it still runs at **`io_full` 10.5–14.7 %**, because its
   database is not in `/tmp` at all — it is in the postgres service
   container, writing to the runner's real disk, where moving our own `/tmp`
   to RAM cannot reach it. The tmpfs stays on that lane: it still takes the
   per-application temp trees off disk, and two lanes running the same target
   are worth more identical than micro-tuned.
4. **The host-versus-cgroup PSI split works, and it is not theoretical.** On
   the sqlite lane `cg_cpu_some` tracks host `cpu_some` almost exactly
   (12.4 vs 13.2, 30.1 vs 30.5, 70.8 vs 71.9) — all the pressure is ours. On
   the postgres lane they diverge hard: host `cpu_some` 21 % against
   `cg_cpu_some` 10 %, and `self cpu` 28–33 % of a box that is 63–67 % busy.
   Something else on that VM is using half the machine, and on that lane it
   is our own postgres service container, which is expected. That is also
   the one live near-miss on the verdict rules: `self cpu` 27.9 % sits just
   above the `≤ 0.4 × busy` threshold, so the "something else in this VM"
   hint did not fire. If it ever does on that lane, a service container is
   the first thing to suspect and the hint text says so.

A new lead falls out of (3): `api-tests-postgres` is I/O-stall-bound too, at
half the sqlite lane's old rate, and its stall is in a container we do not
configure the storage of. It has the narrower spread (3.39× against 4.80×)
and has never been killed, so it is not urgent — but it is now measured
rather than assumed, and it is where that lane's excursions should be looked
for first.

### Where the lane landed (2026-09-16, both changes on `main`)

Both changes are merged: #1531 (tmpfs `/tmp`, `StarvationRecorder`) and #1532
(the migrated template, attack note 5). Measured on `main`, not predicted:

| | `Run APITests` | against the 291 s baseline |
|---|---|---|
| baseline, 213 `main` runs | 291 s | — |
| tmpfs only (`c8720254`) | **185 s** | −36 % |
| tmpfs + template (`9a9c6372`) | **143 s** | **−51 %** |

The postgres lane's equivalent is measured locally rather than on `main` and
is recorded here so the two are read together: 418.9 s -> 117.9 s of test
time on one machine, same command, 3,2xx tests green both ways (attack note 6).
Its `main` population starts at the 391 s median in the table above, and that
is the acceptance test for it too.

3,237 tests in 131.6 s of test time; the job is ~232 s against a 1,500 s
ceiling. The absorbable collapse therefore goes from **4.8× to roughly 10×**,
above every excursion in the 213-run population — all of which were censored
at 4.8× by the kill, so "above every observed excursion" is a weaker statement
than it sounds and is deliberately not phrased as "cannot happen again".

The telemetry from that run is the more interesting half:

```
io_full=0.0%  mem_full=0.0%  steal=0.0%  throttled=+0
busy=88-97%   self cpu=79-90%   scopes=728-1315/min
cg_cpu_some=34.6%  vs  host cpu_some=35.5%
```

- **The I/O stall is gone** — `io_full` 0.0 % in every window, against the
  20-27 % that opened this entry.
- **The lane is now cleanly CPU-bound, and the CPU is ours.** `cg_cpu_some`
  tracks host `cpu_some` almost exactly, so nothing else on that box is
  competing. That is the self-versus-neighbour question answered directly,
  which is what the recorder exists for.
- **Throughput is ~730-1,315 finished tests/min**, against 400-500 before.

One consequence worth stating because it changes what the OTHER attack notes
buy: the lane used to sit with idle cores waiting on disk (`busy` 58-63 %), so
a bigger runner would have bought nothing. It now saturates what it has, so
note 1 (a larger runner) and note 4 (sharding) would both convert — where
before the fix neither would have. Neither is needed at a 143 s median; this is
recorded so the next person to price them starts from the right bottleneck.

**Where the constraint sits now.** With note 6 merged, BOTH lanes are O(1) in
the migration count, which is the property that matters as the suite grows: a
new migration no longer taxes either. The postgres lane was briefly the
binding constraint — ~430 s against a ~1,400 s budget, 3.3x, worse headroom
than `api-tests` had when this investigation opened — and note 6 is what
closed that gap rather than leaving the fix lopsided. Neither lane is near its
ceiling now, so the next thing to watch is not a lane at all: it is whether
the collapse recurs, which is still unexplained and is what the
`[ci-pressure]` lines exist to name.

**What this is NOT.** It is not proof the collapse is gone. Three green runs
prove nothing about an 11 %-of-runs event; the honest acceptance test is the
`main` population over the next few weeks, read against the table above. What
to look for there, in order: whether any `api-tests` run is killed at the
ceiling at all; whether the fraction of runs at ≥2× the new median falls from
10.8 %; and where the median settles against the 143 s first measurement.

**Say plainly which of two outcomes the data shows.** A lane with twice the
headroom can stop producing kills without the collapse ever having been
root-caused, and that is not the same result as fixing it. If excursions
persist at a lower rate, the entry should say so rather than close. A slow run
now carries `[ci-pressure]` lines, and a HINT on one of them names its own
cause — that is the whole point of the instrument, and reading it is the first
step, not another log tail.

---

**Handling while this is open.** Re-run the job (`/rerun-failed`, or
`rerun-failed-jobs`). Before blaming a `cancelled` `api-tests` on the diff in
front of you, check, in order: does the diff touch `Sources/APIServer/` or
`Tests/APITests/` at all; did `api-tests-postgres` pass on the same commit (it
runs the *same target*); were tests still completing at the tail of the log;
and now — **what do the `[ci-pressure]` lines say**. Do NOT use the per-test or
per-suite durations; they are the harness artifact corrected above.

**Reproducing `APITests` locally.** Set
`SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4`, as CI does. Unbounded
Swift Testing parallelism **SIGSEGVs** this target locally with a flood of
AsyncKit "Connection request timed out" — a crash that looks exactly like a
regression in the change under test and is not one. To reproduce the I/O
finding, run it once normally and once with `TMPDIR` on a tmpfs and compare
the recorder's `io_full`.

**Attack notes.** In rough order of cost:

1. ~~**Promote `WedgeWatchdog` to shared test support and arm it in
   APITests.**~~ **DONE, and the claim attached to it was WRONG.** The
   promotion shipped and is worth keeping — APITests genuinely lacked a
   stall guard that survives pool saturation. But this note asserted it
   "will settle the noisy-neighbour-vs-saturation question the next time
   this happens", and it cannot: the watchdog measures silence, and a
   Family 5 lane is never silent. Incident 2 proved it — the watchdog was
   armed, the job burned 25 minutes, and it correctly stayed quiet while
   the job was killed with no evidence. That gap is what
   `StarvationRecorder` closes. Leaving this note as written was worse
   than the gap: it read as though the question were instrumented.
2. **Re-tune the ceiling.** **DONE (25 min) AND SUPERSEDED.** See established
   finding 9: the raise bought nothing net, because suite growth consumed it
   as it arrived. Raising it again would buy a genuine wedge five more minutes
   of silence and would still not rescue a 5× collapse. The lever that works
   is the median, not the ceiling — which is what the tmpfs change pulls.
3. ~~**Finish the CLOEXEC sweep.**~~ **DONE**, and measured not to be
   reachable — see "Remaining attack order" item 3. The leaked-write-end
   mechanism cannot be the cause of a Family 5 event.
4. **Shard `api-tests` — NOT DONE, and now second in line.** Splitting the
   target across N jobs divides the median by ~N and multiplies the absorbable
   collapse by ~N, the same lever the tmpfs change pulls and stackable with
   it. It is second because Swift Testing has no sharding primitive: it would
   be `--filter` regexes over suite names, and a new suite landing outside
   every shard's filter would never run and never fail — the silent-skip trap
   this repository has been burned by repeatedly (see the `browser-runner-tests`
   and Rscript notes in `swift-tests.yml`). It needs a guard proving the
   shards' union is the whole target before it is worth doing. Revisit if the
   `main` population still shows kills once the tmpfs change has a few weeks
   of history.
5. **Cut the per-test application builds — DONE (PR #1532), and it was the
   biggest single lever of the three.** This note used to say "only worth it
   if the population still shows a problem after 4". That was the wrong test
   to gate it on, because the measurement was cheap and settles it outright.

   A throwaway probe split what building one test application costs:

   ```
   bare Application.make + shutdown    1.1 ms
   + configureTestDatabase           357.8 ms   <- 60 migrations, ~5.9 ms each
   full makeTestApp                  389.0 ms
   ```

   **`autoMigrate` is 92 % of it.** Against the ~1,100 per-test Applications
   this suite's own helper documents, that is ~390 of the ~660 core-seconds a
   width-4 run has — roughly **60 % of the lane re-deriving a schema that is
   identical every time**.

   And the cost is a PRODUCT, migrations x applications, with both terms
   growing: since 2026-05 migrations went 28 -> 60 (one consolidation at the
   0.5 boundary, `fe764cbb`) and APITests files 59 -> 375. Up ~13x. That is
   the mechanism behind the median creep recorded in finding 9 — every new
   migration taxes every existing test, and every new test pays for every
   existing migration. It is also why items 1 and 4 are lesser levers: a
   bigger runner and more shards both DIVIDE a number that keeps growing,
   while migrating once per process into a template and copying the file per
   test makes the per-test cost **O(1) in the migration count**. The next
   migration anyone writes costs this suite nothing.

   Measured, same machine, identical tree except `Tests/APITests/TestHelpers.swift`,
   3,215 tests passing both ways: **277.6 s -> 91.9 s** (replicated:
   91.9 / 89.0 / 91.2 / 97.7). No production code changed —
   `DatabaseSettings.sqlite(path:)` already existed, and sqlite-kit's
   `.memory` was itself a temp file on disk, so this swaps one file for
   another rather than memory for disk.

   **What it did NOT cover, and what covers it now.** This note used to end
   "the postgres lane keeps its per-test schema: a file copy has no analogue
   there (it would want `CREATE DATABASE ... TEMPLATE`, a different
   mechanism)". The first half was right and the second was the wrong
   analogue. See item 6 below: the postgres lane gets the same O(1)-in-
   migrations property from recycling a migrated SCHEMA, and
   `CREATE DATABASE ... TEMPLATE` was measured and rejected on the way.

   **Three defects it surfaced, which is the part worth keeping.** Skipping
   `registerMigrations` alongside `autoMigrate` (only running is expensive;
   registering builds a list) made `autoMigrate` a silent no-op, caught by
   `MigrationNamespaceReconcilerTests` requiring a deliberately-reverted
   `CreateSweepLeases` to be applied forward. Actor reentrancy across `await`
   built the template three times per run — caught by counting leftover files,
   not by any failing test. And the leak guard
   `TestAppTempDirectoryTests.withAppLeavesNothingBehind` asserted on ONE
   mechanism by name (`sqlite-kit_memorydb-*`), so adding a second emptied its
   input: it now asks `sqliteDatabaseFilesOnDisk()`, which covers both. That
   last one generalises, and belongs next to this file's other guard lessons:
   **a guard pointed at a mechanism by name is a guard that changing the
   mechanism silently empties.**

6. **Give the postgres lane the same O(1) — DONE, by recycling schemas rather
   than copying files.** Item 5 left that lane running 60 migrations per test
   application, and it was then the lane with the least ceiling headroom:
   ~391 s median against a ~1,400 s budget, 3.4x, against the sqlite lane's
   ~10x.

   The same probe, run against a local Postgres 16.13:

   ```
   bare Application.make + shutdown        0.9 ms
   + connect and CREATE SCHEMA            11.0 ms
   + autoMigrate                         450.6 ms   <- 98 % of the cost
   ```

   Three mechanisms were measured, not one:

   | | cost | vs. 460 ms to migrate |
   |---|---|---|
   | `CREATE DATABASE ... TEMPLATE` | 195.8 ms create + 158.9 ms drop | **1.3x — rejected** |
   | `TRUNCATE` all 44 tables | 139 ms | 3.0x |
   | `DELETE` sweep, one `DO` block | **1.7 ms** | **244x** |

   So the shipped mechanism is a process-wide pool of pre-migrated schemas
   (`MigratedPostgresSchemaPool` in `Tests/APITests/TestHelpers.swift`), one
   checked out per test application and DELETE-swept on return. Measured on
   the same machine, same command, 3,2xx tests green both ways:
   **`Run APITests` 418.9 s -> 117.9 s (-72 %)**, against a naive projection
   of ~280 s — the same direction the sqlite change beat its own estimate in.

   Three things are worth carrying forward from it more than the number.

   *The `DELETE` sweep is one statement, not 44.* A plpgsql block runs each
   statement separately and a foreign key's integrity trigger fires at the end
   of the statement that armed it, so 44 `DELETE`s joined by 57 foreign keys
   need a topological order and break on the first cycle. One data-modifying
   `WITH` leaves every check to fire after all of them are already empty, and
   no order exists to get wrong.

   *`DELETE` does not reset sequences, and the answer was to refuse rather
   than assume.* Every `@ID` in `Sources/APIServer/Models` is client-generated
   and every `.identifier(` in `Sources/APIServer/Migrations` is
   `auto: false`, so there is nothing to reset today — but the pool asks the
   DATABASE for its sequences at migration time and refuses to recycle a
   schema that has any, naming the fix in the message. A source scan states
   the same claim in the other direction.

   *The guard that names a suite is not the guard that holds.* One suite
   (`MigrationNamespaceReconcilerTests`) rewrites the migration log on
   purpose and must have a schema of its own, which means naming it — the
   shape item 5's third defect warns about. So the pool also fingerprints
   every schema on the way back in (relations plus migration-log rows, md5,
   checked inside the same `DO` block) and drops and rebuilds any that came
   back different, keyed on the damage rather than on who did it. That is
   what found `MCPAuditFailClosedTests`, which drops the `audit_log` table
   and which a hand search had missed by not recursing into
   `Tests/APITests/MCP/`. The name-based list is now backed by a source scan
   that fails when the sources and the list disagree.

   **The defect it surfaced is worth more than the number: `withApp` could
   kill the whole test process, and had been able to for as long as it has
   existed.** It was

   ```swift
   do { try await body(app); try await app.tearDownTestApp() }
   catch { try? await app.tearDownTestApp(); throw error }
   ```

   which tears down TWICE when the tear-down inside the `do` is the thing that
   throws. A second `tearDownTestApp` on an application that is already shut
   down does not throw — it is `Vapor/Core.swift: Fatal error: Core not
   configured`, which takes the process, not the test. Nothing in the suite
   made teardown throw, so the path was never walked; a pool check-in can
   throw, and it walked it on the first full run as a bare `signal 4`
   mid-suite.

   Note the shape, because it is the same one as Family 1 and #1233 and it is
   the third time this file has recorded it: **a latent whole-process kill,
   invisible while one precondition happened to hold, surfacing as an
   unexplained signal rather than as a failing test.** The precondition here
   was "teardown never throws", which nothing stated or guarded. Teardown now
   runs exactly once however the body ends, and `tearDownTestApp` holds its
   first error and completes every remaining cleanup step rather than
   short-circuiting — a throwing `asyncShutdown()` used to skip every removal
   below it, which was a leak before the pool and a run-stopper after it.

   **Independently re-measured before merge** (a second machine-local A/B by
   the reviewing session, not the authoring one): postgres lane
   **391.0 s -> 119.3 s, −69 %**, zero schemas left behind; the sqlite lane
   **91.8 s**, unchanged. The −72 % above is against a 418.9 s baseline and
   −69 % against a 391.0 s one; the spread is that lane's own run-to-run
   variance, which is the subject of this entry and is why both are quoted
   rather than the better.

**The arming guard's own first flake (2026-08-22) — FIXED.** The watchdog's
drift guard `WedgeWatchdogArmingTests.withAppArmsTheWatchdog` was itself the
sole failure in a 3,045-test `api-tests-postgres` run (run 32542491009,
branch `claude/student-avatar-generation-t2suku`; the sqlite lane passed the
same commit, and the diff — avatar art — cannot reach it). The assertion
compared two reads of the process-global `activeTrackedScopes` counter,
before `withApp` and inside it: under parallel tests that delta is racy,
because every concurrent test's scope moves the same counter. On this run
the lane was heavily contended (postgres checkpoints of 60+ s in the service
log; the test body took 66.5 s), so the window between the reads was wide
enough for every other in-flight scope to drain — one net −1 by others plus
our own +1 reads as "no increase", and `(scopesInside → 1) > (scopesBefore
→ 1)` failed.

The fix replaces the delta with a `@TaskLocal` — `WedgeWatchdog.track` now
sets `isInsideTrackedScope` for its body, and the test asserts it from
inside `withApp`. Task-locals follow the task tree, so another suite's scope
can neither satisfy the assertion (no false pass through, say,
`withPatternFamilyFixture`'s self-arming) nor disturb it (no false fail from
scopes draining concurrently) — strictly stronger than the counter delta and
race-free. The global counter keeps its job as the monitor's arming signal;
the test still pins a same-instant floor (`activeTrackedScopes >= 1` from
inside the scope, which concurrent activity can only raise).


---

## Structural problems → current state

1. **A bot's only re-kick was a new SHA.** Fixed: comment `/rerun-failed`
   on a PR (`rerun-failed.yml`, OWNER/MEMBER/COLLABORATOR only) re-runs
   only the failed/cancelled runs for the current head SHA via
   `rerun-failed-jobs`. An empty-commit push re-rolls every flaky die and
   invalidates the shared build cache key for nothing; the comment re-rolls
   one die and reuses every green result.
2. **Compounding probability.** A UI-touching PR rolled at least three dice
   per run (worker-tests, grading-probe webkit, smoke webkit). Family 1's
   fix removes the biggest term; the webkit tolerances remove most of the
   rest. Expected composite failure rate on a loaded afternoon drops from
   ~50 % to the residual chromium/webkit-double-hang rates.
3. **Silent-stall failure shapes burned the most wall-clock.** Fixed at
   three layers: bounded waits in the runner itself, `.timeLimit` on the
   stall-capable suites, and (unchanged) the job-level `timeout-minutes`
   backstop.
4. **A one-in-thousands failure had no reproduction tool.** Fixed:
   `repeat-test.yml` (Actions tab, "Repeat a test") runs one `--filter`
   selection up to N times on the CI image and stops at the first failure,
   using Swift 6.4's `swift test --maximum-repetitions N --repeat-until
   fail`. The log and the xUnit report are uploaded either way. The
   2026-08-22 `withAppArmsTheWatchdog` failure (1 in 3,045, above) was
   diagnosed by reading LeafKit-adjacent theory into a single log; the same
   question is now a dispatch and a wait. It reproduces a test's own flake,
   not a lane's: a full `api-tests` lane loads the box in a way one repeated
   test does not, so a Family 5 collapse is still measured on the `main`
   population and read from the `[ci-pressure]` lines.

## Remaining attack order

1. **Exec-hang root cause** (Families 2+3 shared it) — **overtaken by the
   substrate change (2026-08-22): see the status revision at the end of
   Family 2.** The archived trail targeted pyodide-kernel-driver code that
   no longer ships; a new hang starts from the probe's five-way
   classification, and the dispatch/scheduled hard-zero runs of
   `grading-hang-probe.yml` remain the acceptance test for any fix. The
   findings below are the old era's record, kept because the probe
   forensics they produced (the classifications, the dialog capture, the
   delay experiment's method) survive the substrate they measured.

   *2026-07-02 evening findings (probe forensics upgraded in the same
   change as this note):*
   - Production telemetry (admin `get_browser_diagnostics`, 96 h window)
     shows the **sustained-busy `exec_hang` is still real for students on
     current builds**: 19 hangs / 465 `kernel_idle` boots (~4 %), 19
     self-heal attempts, 2 `recover_failed`. The v0.4.526 chdir fix killed
     the 100 % class; this ~4 % residue is a distinct bug.
   - The **CI probe hang is a different shape**: the 2026-07-02 chromium
     repro (`hangs=1/8`) showed `indicator=idle` for the full budget and
     `exec_hang=none` — the cell likely never *started*, i.e. the
     Shift+Enter dispatch was lost (post-idle focus race), not a wedged
     kernel. `editor-exec-check.mjs` now classifies this (`lostDispatch`)
     via a second-press discriminator, captures console-error URLs +
     all ≥400 responses + failed requests (the four bare 403s in that repro
     were unidentifiable), reports per-iteration noise base rates on green
     runs too, and dumps the cell prompt/focus state on every hang.
   - **Open lead:** `unhandledrejection: Cannot read properties of null
     (reading 'insertWidget')` fires on essentially every production boot
     (499 events / ~500 boots in 96 h; vendored `jlab_core` bundle, source
     maps checked in). Probably a benign JupyterLab race in the SW-free
     config, but it is exactly the kind of degraded widget state that
     could eat a keypress — worth tracing via the source map before
     trusting it. Confirmed present on every CI boot too (both engines),
     alongside a `updateRenderOption` null error.
   - **First instrumented 45-iteration webkit dispatch:** the constant
     4xx noise is identified — `POST /api/v1/client-diagnostics` 403 plus
     403s on JupyterLite contents-API *folder-creation* attempts
     (`Untitled Folder/all.json`, `users/all.json`,
     `Untitled Folder1/all.json`): the editor's file browser appears to
     try to materialize the missing `users/<uid>/<setup>` path over HTTP
     and is refused on every boot. The one red iteration was a
     **boot-stall** (kernel never idle in 90 s), matching production's
     ~7 % boot→no-idle funnel drop — a distinct phenomenon, not a
     post-idle hang.
   - **CONFIRMED (three-run delay experiment, 2026-07-02 evening): the
     webkit slow-execute mode is a fixed-endpoint post-idle background
     task, not load jitter.** Pressing run at `kernel_idle`+0 ms: 13/45
     iterations wait 16.2–18.2 s; at +1,500 ms: 12/45 wait 15.7–16.7 s
     (the band shifts DOWN by the delay — fixed endpoint, not fixed
     cost); at +25,000 ms: **0/28 slow, every iteration ~510 ms**
     (p ≈ 4×10⁻⁵ by chance). Something occupies the webkit kernel for
     ~17–18 s after idle; a cell executed inside that window queues
     behind it; its far tail is the ambient CI hang and, on slow student
     hardware, plausibly the residual ~4 % production `exec_hang` (the
     45 s telemetry threshold would classify a long-enough wait as a
     hang, and the self-heal reload would "fix" it). It is NOT nb_mypy
     (disabled — see `scripts/patch-pyodide-kernel.py`; CLAUDE.md was
     stale on this and has been corrected). Chromium completes the same
     work fast enough to never lose the race (0 slow in 75+ iterations).
     **Next step:** identify the task — timestamp post-idle kernel/editor
     activity (kernel-wheel patch instrumentation or a performance-trace
     capture in the probe) and inspect what JupyterLite schedules after
     `kernel_idle` in the SW-free config.
   - **Cumulative webkit classification, 135 instrumented iterations:**
     0 post-idle deadlocks, 0 lost dispatches, 1 boot-stall, 3 upstream
     WebKit WASM crashes (bug #286266, classified separately, non-
     failing). The "ambient webkit exec-hang" decomposes into the wasm
     crash + boot-stalls + the fixed-endpoint blocker's tail, with
     nothing left over so far.
   - **NEW class — DIALOG-STEAL (2026-07-02 chromium, forensic capture).**
     A chromium exec-probe "hang" turned out to be a modal JupyterLab
     dialog: `cell: prompt="[ ]:" active="jp-Dialog-button jp-mod-accept
     jp-mod-styled"` — the cell never dispatched because a `.jp-Dialog`
     had keyboard focus and swallowed the Shift+Enter (the second press
     hit the dialog too, so it wasn't lost-dispatch either). This is a
     distinct, student-facing bug: an error/confirm dialog over the
     editor makes the first run silently do nothing. Very likely tied to
     the every-boot folder-creation 403s + the `insertWidget` /
     `updateRenderOption` null errors — the editor fails to set up its
     working folder and surfaces a dialog. The probe now detects a
     `.jp-Dialog` at hang time, captures its header/body text, dismisses
     it, and re-presses to confirm the kernel underneath is healthy;
     classified as `dialogSteal` (reported, non-failing). **Next step:**
     read the captured `dialog:` text from the next probe run to identify
     which dialog, then fix the folder-setup path that raises it.
   - **Probe classes are now fully separated (post-boot-stall-split).**
     The probe distinguishes five outcomes so each maps to one
     phenomenon: `deadlock` (reached idle, execute wedged — the only
     leg-failing class), `bootStall` (never reached idle), `dialogSteal`
     (modal dialog ate the keypress), `lostDispatch` (keypress lost, no
     dialog), and `webkitWasmCrash` (upstream #286266). Boot-stalls and
     dialog-steals used to be miscounted as deadlocks; a 30-iteration
     chromium run's lone failure was a boot-stall (`iter 5/30 ... kernel
     never reported idle, waited=0ms`), now labelled as such.
   - **Grading-hang probe: chromium also hangs (`1/12`, 2026-07-02).**
     Not webkit-only. The grading path (a SECOND Pyodide in
     grading-worker.js) intermittently never completes on chromium too;
     the breadcrumb trail on the failing iteration is the lead. The gate
     correctly held chromium to zero (webkit's PR tolerance does not
     apply), so this failed the non-required probe — signal, not a
     blocker.

4. **Residual WorkerDaemonTests wedge — ROOT-CAUSED (issue #1233,
   2026-07-29).** With the fork bug fixed, worker-tests wedged once more
   (2026-07-02: `workerDaemonContinuesToNextJobAfterProcessingFailure`
   failed its 10 s wait, then the bare `try await task.value` after
   `task.cancel()` suspended forever — `Task.value` is not
   cancellation-responsive). All cancel-then-await sites were bounded via
   `awaitCancelledDaemon` (30 s), yet on PR #1230 the 20-minute wedge
   recurred **twice on one SHA** with the containment in place: 254 tests
   started, 55 completed, ~18 minutes of total process silence
   (issue #1233).

   **Mechanism (whole-process, not per-test).** The observed "last log
   lines" were victims: one was a pure-mock runner mid-`Task.sleep`, the
   other a test frozen at its first suspension after `job_accepted` —
   i.e. the *scheduler* stopped, not those tests. The cooperative pool
   (~one thread per core, never grows) was fully pinned by blocking
   subprocess waits running on pool threads: `MimeTypeDetector` spawned
   `/usr/bin/file` per submission file per job with a blocking
   `readDataToEndOfFile()` (unthrottled — production code, so outside
   `SubprocessThrottle`), `runProcessRobustly` blocked in
   `waitUntilExit()`, `LocalHTTPTestServer.readPort` blocked in
   `availableData` (its deadline was only re-checked *between* chunks),
   and several test files carried raw read-to-EOF/`waitUntilExit` calls.
   Each is nominally bounded by its child — but the #1139 CLOEXEC fix
   covered only ScriptRunner's pipes, so these pipes' write ends leaked
   into every concurrently spawned process; a long-lived inheritor (a
   test HTTP server) postpones EOF indefinitely. Once pinned threads ≥
   pool width, test `defer`s can never run, servers are never killed,
   the leaked write ends never close — a transient overload becomes a
   **permanent, self-sustaining wedge**. `.timeLimit` and
   `awaitCancelledDaemon` need a pool thread to fire, which is why
   neither could help. Load-dependence, local cleanliness, and
   pass-on-retry all follow.

   **Fixes (same PR as this note).** (a) CLOEXEC + deadline-bounded
   drains on every worker/test subprocess pipe (`setCloseOnExec` now
   internal; `boundedReadToEOF` shared); (b) `runProcessRobustly` awaits
   exit via termination handler + SIGKILL escalation instead of pinning
   a pool thread; (c) `readPort` is poll-based so its deadline is real;
   (d) the daemon-side answer to "what ignores cancellation":
   `TestSetupCache.acquire` awaited unstructured `Task.value`s — it now
   uses cancellation-responsive continuations, and the shared populate
   task is itself cancelled when its last waiter detaches, so a
   cancelled daemon stops in-flight artifact downloads (regression
   tests deadlock against the old code); (e) `awaitCancelledDaemon`
   records a loud Issue + thread dump when it abandons a daemon;
   (f) a **WedgeWatchdog** on a dedicated OS thread (immune to pool
   saturation) aborts with a full `/proc/self/task` thread table
   (state + `wchan` per thread) after 5 minutes of helper-in-flight
   silence — a future wedge fails in ~6 minutes *with evidence* instead
   of burning 20 silent ones. `CHICKADEE_WORKERTESTS_STALL_SECONDS`
   overrides (0 disables).
2. **Watch the tolerated-webkit warning rate.** The `::warning`
   annotations from the probe and the smoke retries are the flake-rate
   telemetry now; if they show up more than occasionally, the ambient rate
   is rising and the tolerance should be revisited (in either direction).
3. **Other blocking subprocess reads** — swept in the follow-up PR. The
   two read-after-wait sites are fixed: `MimeTypeDetector` drains before
   waiting, and `PersonalizationEvaluator` drains both pipes concurrently
   with a deadline before waiting (plus SIGKILL escalation when an
   expression's interpreter ignores SIGTERM, and no more full-timeout
   sleep on the return path). `Core/ZipArchiver`, `TestSetupZipHelpers`,
   and `NotebookContentHelpers` already read before waiting (the safe
   order); their pipes still aren't CLOEXEC — a cosmetic residual to fold
   in when those files are next touched. **DONE — and the premise turned out
   narrower than this item stated.** The three helpers are CLOEXEC'd (via
   `Core/PipeCloseOnExec.swift`, hoisted from the worker's copy so there is
   one implementation), but measurement says the leak is **not reachable
   through anything Chickadee spawns today**: on Swift 6.3 / glibc 2.39 a
   pipe of ours does not survive into a child spawned through Foundation's
   `Process`, and swift-subprocess — the worker's spawner —
   `close_range(…, CLOSE_RANGE_CLOEXEC)`s everything above stderr. Only a
   bare `posix_spawn` child still inherits, which is what the behavioural
   test has to use to demonstrate the failure at all.

   So the change is defence-in-depth restoring a uniform invariant, not a
   live bug being closed, and **the leaked-write-end mechanism cannot be the
   cause of a Family 5 event.** An intermediate revision of this file
   reclassified "cosmetic" as an unmeasured assumption; that reclassification
   was itself the unmeasured thing, and the original wording was closer to
   right. `Tests/CoreTests/PipeCloseOnExecTests.swift` pins the measurement so
   a toolchain change that re-opens the leak is caught here rather than in a
   wedged job. Note the precise claim: *our pipe's write end* does not reach
   the child. Other inherited descriptors do — "the child holds only fds
   0/1/2" is too strong and measures false.

   **Superseded by the swift-subprocess migration.** `Core/PipeCloseOnExec.swift` and its test are
   gone, and so is the worker's `boundedReadToEOF`. The swift-subprocess
   migration removed every hand-built `Pipe` those helpers guarded: the three
   zip/notebook helpers spawn through `Core/ZipSubprocess.swift`, and
   `ScriptExecution` builds its own CLOEXEC pipes inline because Subprocess's
   pipes do not set the flag. The measurement above still holds — it is simply
   no longer pinned by a test, because the code it measured no longer exists.
   One hand-built `Pipe` remains, in `LocalHTTPTestServer`, and it sets the
   flag itself.
4. **Stall visibility in `api-tests`** (Family 5) — **DONE, and the
   Family 5 half of the claim was wrong; see that entry.**
   `WedgeWatchdog` moved to a shared `ChickadeeTestSupport` target (a plain
   `.target`, because a `.testTarget` cannot be depended on and SwiftPM
   assigns each source file to exactly one target, so there is no
   shared-`sources:` trick that does not compile two copies of the type). It
   is armed in `APITests` at `withApp` in `TestHelpers.swift` — 172 of the
   target's 315 files call it directly, and `withWebRoutesApp` /
   `withAssignmentRoutesApp` funnel into it; `withPatternFamilyFixture`
   builds its app directly and so arms itself. `WedgeWatchdogArmingTests`
   guards against silently losing the arming. All of that is worth keeping:
   APITests genuinely lacked a stall guard that survives pool saturation, and
   now has one.

   What it does NOT do is give Family 5 an instrument. The watchdog measures
   silence; a Family 5 lane is never silent. Incident 2 (2026-09-15) is the
   demonstration — armed watchdog, 25 minutes burned, watchdog correctly
   quiet, job killed with no evidence. `StarvationRecorder` is the half that
   was missing, and it arms from this same seam.

   **The 300 s threshold is measurement-backed, not guessed.** A full
   `APITests` run at CI's `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4`
   passes with the limit forced to **30 s** — 10× tighter than shipped — while
   individual tests in that same run reported up to **131 s of wall clock**.
   That is the design's central distinction demonstrated: a long test is not a
   silent process, and Family 5's steady-progress-at-high-cost would not trip
   it. (Those reported per-test wall clocks are mostly queueing rather than
   work — see the Family 5 correction — which makes the threshold if anything
   more conservative than it looked.) Verified to fire by pinning every
   cooperative-pool thread in a blocking `read(2)` inside an armed scope: the
   process aborted on the watchdog's own thread with a `/proc/self/task` table
   showing four `state=S wchan=anon_pipe_read` pool threads.

   No new environment variable: `CHICKADEE_WORKERTESTS_STALL_SECONDS` keeps
   its name and 300 s default even though it now covers two targets, because
   renaming it would silently drop an existing override. `StarvationRecorder`
   adds none either, and deliberately keeps recording when that variable is
   set to 0 to disable the abort.

## Evidence index

- Issue #1139 — `stdoutIsCaptured` flake, with the four-run table.
- PR #1138 — the four byte-identical runs (28586988643, 28588059980,
  28588705591, 28589351648).
- Stress repro (this doc, Family 1) — old 8/200 vs fixed 0/3000.
- `docs/archive/exec-hang-investigation.md` — the webkit exec-hang root-cause work.
- `grading-hang-probe.yml` run history — background failure rate on
  unrelated branches (2026-06-26 ×3).
- `editor-smoke.yml` run history — 24/25 green over the trailing window.
- PR #1308 (Family 5) — run 31316093551, `api-tests` attempt 1 job
  93253094895 (`cancelled`, `Run APITests` 1107 s) vs attempt 2 job
  93255901938 (`success`, 216 s) on the same commit `07efab8`.
- `swift-tests.yml` run history on `main`, 2026-08-08 → 2026-08-09 (Family 5
  baseline) — 18 runs, `api-tests` 204/236/441 s min/median/max against
  `api-tests-postgres` 257/330/351 s. Superseded as a baseline by the
  213-run population below; kept because the comparison between the two is
  what shows the suite's cost creep.
- PR #1529 (Family 5 incident 2) — `api-tests` `cancelled` at the 25-minute
  ceiling on `f8ffb34`, 966 tests completed, last completion 3 s before the
  kill; `api-tests-postgres` green on the same commit in 11 min;
  `rerun-failed-jobs` green in 7 m 43 s; diff contained no Swift.
- `swift-tests.yml` run history on `main`, 2026-08-10 → 2026-09-16 (Family 5
  population) — 213 runs × 5 lanes, per-step durations from the Actions API.
  `build` 0/213 runs ≥2× its median; `api-tests` 23/213. Five `main`
  ceiling kills: jobs 95852055877, 96206596827, 96218450897, 96508206917,
  97961643124.
- Family 5 harness-artifact repro — 64-test package, every body a 400 ms
  sleep, `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4` on Swift 6.3:
  4 concurrent bodies, last test reports "passed after 6.408 seconds".
- Family 5 tmpfs measurement — full `APITests` at CI's parallelization width,
  same machine and build: `/tmp` on disk 287.6 s / 274.9 s with PSI
  `io_full` 20-27 %; `/tmp` on tmpfs 165.7 s / 162.1 s with `io_full`
  0.0-0.2 %; peak tmpfs occupancy 4 MiB.
