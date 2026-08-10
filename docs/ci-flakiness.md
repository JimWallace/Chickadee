# CI flakiness — state of knowledge (2026-07-02, last extended 2026-08-09)

Handoff document for the flakiness work. Families 1–3 are the original
2026-07-02 body; **Family 4 (2026-08-05) and Family 5 (2026-08-09) were added
later**, so the header date is where this started, not where it ends. Check
the newest families first — they are the ones still open.

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

## Family 2 — webkit grading hang (`grading-probe (webkit)`, `hangs=N/12`) — CONTAINED, root cause open

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

A hypothesis worth checking against that output when it arrives, not before:
`submitBrowserResult` wraps the submission insert and the result save in
`withTransientDatabaseLockRetry` — someone has already met SQLite lock 500s on
this endpoint — but `awardFirstToSubmitRecords`, `flagResultForBrightSpaceSync`
and the class-records writes in the same handler are not wrapped. If the next
log line reads `database is locked`, that is where to look.

**Root cause** of Family 2 remains the exec-hang investigation's to close —
continue from the probe's `grading breadcrumbs:` per-phase timings on an
iteration whose trail stops before `suite_done`.

## Family 3 — webkit editor smoke, post-idle execute (`smoke (webkit)`) — CONTAINED, same root cause as Family 2

**Symptom.** The editor-smoke selftest's post-idle probe fails:
`post-idle execute passed? 0 (want 1)` — kernel never runs the expression.
~1 failure in 25 gate runs, and `smoke` feeds `editor-smoke-gate`, the
**required** check — so this family, though rarest, hard-blocked merges.

**Containment (shipped).** The webkit legs of the `smoke` job (selftest and
notebook-page e2e) get exactly one retry, logged with a `::warning` so the
flake rate stays visible in annotations. Chromium legs stay strict — a
chromium failure is treated as real, first time.

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

---

## Family 5 — `api-tests` starved past its 20-minute ceiling — OBSERVED ONCE (2026-08-09), root cause open

**Symptom.** `api-tests` reports **`cancelled`** and `swift-tests-gate` fails
with `jobs not successful: api-tests`. It reads exactly like the Family 1 /
#1233 wedge — same conclusion string, same 20-minute burn — and it is **not
one**.

**What distinguishes it from a wedge: the job was still making progress at
the moment of the kill.** The last seconds of log show tests *completing*,
not silence:

```
✔ Test requestJob_concurrentClaims_onlyOneSucceeds() passed after 10.517 seconds.
✔ Test getResultsReturnsCollection() passed after 10.015 seconds.
```

A wedge produces ~18 minutes of total process silence (#1233: 254 tests
started, 55 completed). This produced steady completions at roughly 10×
their normal cost. The distinguishing question is therefore **"is anything
still finishing?"**, not "did the job hit its ceiling?" — both shapes hit the
ceiling.

The second tell is in the suite wall-clocks. Three unrelated suites reported
near-identical totals:

```
✔ Suite DraftSuiteSectionRoutesTests passed after 1083.174 seconds.
✔ Suite OctavePatternFamilyExecutionTests passed after 1086.623 seconds.
✔ Suite AuthModeGatingTests passed after 1086.744 seconds.
```

Every suite starting at ~t=0 and ending at ~t=1085 is one contended parallel
pool draining, not three suites that each took 18 minutes.

**The measurement.** PR #1308 (`07efab8`), both attempts of the same job on
the same commit, ~25 minutes apart:

| | attempt 1 | attempt 2 (`rerun-failed-jobs`) |
|---|---|---|
| `Run APITests` | **1107 s** — killed at the ceiling | **216 s** |
| conclusion | `cancelled` | `success` |
| runner | `GitHub Actions 1000033632` | `GitHub Actions 1000033636` |
| setup before the step | 93 s | 92 s |

No code changed between them. **216 s is below the main median**, so attempt 2
was not a lucky fast run — attempt 1 was a >5× outlier.

**Baseline** (`Run APITests` step, last 18 completed `main` runs, 2026-08-08
to 2026-08-09):

| lane | ceiling | min | median | max | spread |
|---|---|---|---|---|---|
| `api-tests` (sqlite) | 20 min | 204 s | 236 s | 441 s | **2.2×** |
| `api-tests-postgres` | 25 min | 257 s | 330 s | 351 s | 1.4× |

Two things fall out of that table:

1. **The effective budget is the ceiling minus setup**, not the ceiling.
   Container init + checkout + artifact restore cost ~93 s, so `Run APITests`
   gets ~1107 s of a 1200 s job — which is exactly where attempt 1 was
   killed.
2. **The more variable lane has the tighter ceiling.** The sqlite lane swings
   2.2× run-to-run and is capped at 20 min; the postgres lane is far steadier
   and gets 25. That inversion is not deliberate, and it means the lane most
   likely to spike is the one with the least room to.

**What is NOT established.** A single observation cannot separate these, and
the entry is written so nobody later mistakes the hypothesis for the finding:

- *Ambient runner slowness / noisy neighbour.* Not excluded. The two attempts
  ran on different runners, and 4.7× is a lot but hosted runners do vary.
- *A saturation event of the #1233 kind that happened to recover.* The
  identical-wall-clock signature is consistent with the pool filling; the fact
  that tests kept completing says it never became self-sustaining. #1233's
  analysis is explicit that the permanent form needs leaked pipe write ends to
  postpone EOF forever — so a transient version that drains is the *expected*
  benign relative of that bug, not evidence of it.

**Why APITests is the plausible host if it is the second one.** The exposure
that made `WorkerTests` wedge is present here and has never had the same
treatment:

- **35 of 314 `Tests/APITests/` files spawn `Process()`; 29 name a real
  interpreter** (`python3`, `Rscript`, `lua`, `octave-cli`, `racket`, `g++`).
  That surface grew through the 0.5.3x language work, and recently: the log
  excerpt above shows `OctavePatternFamilyExecutionTests`, added
  **2026-08-07** — two days before this incident.
- **`WedgeWatchdog` is `WorkerTests`-local.** It lives in
  `Tests/WorkerTests/Support/WedgeWatchdog.swift`; `Tests/APITests/`
  references it **0 times** against `WorkerTests`' 6. It is the one mechanism
  that survives pool saturation, because it runs on a dedicated OS thread.
- **APITests has 32 files carrying `.timeLimit`** — and per #1233 that is
  precisely the protection that *cannot* fire under saturation, since the
  trait needs a pool thread to run. So APITests currently holds the guard
  that doesn't work in this scenario and lacks the one that does.

The CLOEXEC residual noted in "Remaining attack order" item 3 is on this
side of the tree too: `Core/ZipArchiver`, `TestSetupZipHelpers` and
`NotebookContentHelpers` read before waiting (the safe order) but their pipes
still aren't CLOEXEC.

**Handling for now.** Re-run the job (`/rerun-failed`, or
`rerun-failed-jobs`). Before blaming a `cancelled` `api-tests` on the diff in
front of you, check three things, in order: does the diff touch
`Sources/APIServer/` or `Tests/APITests/` at all; did `api-tests-postgres`
pass on the same commit (it runs the *same target*, and did here); and were
tests still completing at the tail of the log. All three pointed away from the
diff on #1308, and the rerun confirmed it.

**Reproducing `APITests` locally.** Set
`SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4`, as CI does. Unbounded
Swift Testing parallelism **SIGSEGVs** this target locally with a flood of
AsyncKit "Connection request timed out" — a crash that looks exactly like a
regression in the change under test and is not one.

**Attack notes.** In rough order of cost:

1. **Promote `WedgeWatchdog` to shared test support and arm it in APITests.**
   **DONE** — see attack-order item 4 for what shipped and the measurements
   behind the threshold. Turns a silent 20-minute burn into a bounded failure
   carrying a `/proc/self/task` thread table, which is what will settle the
   noisy-neighbour-vs-saturation question the *next* time this happens rather
   than requiring another lucky log tail.
2. **Re-tune the ceiling — but do not expect it to have saved this run.**
   The sqlite lane is capped at 20 min against postgres' 25 despite carrying
   the wider spread, and equalising them is defensible on the baseline alone:
   the ordinary tail is 441 s, and 20 min leaves ~1107 s of test budget after
   setup. What the bump does **not** do is rescue attempt 1 — that job was
   killed at 1107 s *while still running*, so nothing establishes it would
   have finished inside a 25-minute budget (~1407 s of test time) either. An
   earlier draft of this note asserted it would have passed; that was
   unsupported, and the correction is the point: this buys headroom for the
   ordinary tail, not for a 5× starvation event. It also buys a genuine wedge
   five more minutes of silence, which is why it belongs after (1) rather
   than instead of it.
3. **Finish the CLOEXEC sweep** on the three helpers above, closing the
   mechanism that turns a transient overload into a permanent one.

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

## Remaining attack order

1. **Exec-hang root cause** (Families 2+3 share it) — continue from
   `docs/archive/exec-hang-investigation.md` with the probe breadcrumbs. The
   dispatch/scheduled hard-zero runs of `grading-hang-probe.yml` are the
   fix's acceptance test.

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
4. **Stall visibility in `api-tests`** (Family 5) — **DONE.**
   `WedgeWatchdog` moved to a shared `ChickadeeTestSupport` target (a plain
   `.target`, because a `.testTarget` cannot be depended on and SwiftPM
   assigns each source file to exactly one target, so there is no
   shared-`sources:` trick that does not compile two copies of the type). It
   is armed in `APITests` at `withApp` in `TestHelpers.swift` — 172 of the
   target's 315 files call it directly, and `withWebRoutesApp` /
   `withAssignmentRoutesApp` funnel into it; `withPatternFamilyFixture`
   builds its app directly and so arms itself. `WedgeWatchdogArmingTests`
   guards against silently losing the arming.

   **The 300 s threshold is measurement-backed, not guessed.** A full
   `APITests` run at CI's `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4`
   passes with the limit forced to **30 s** — 10× tighter than shipped — while
   individual tests in that same run reported up to **131 s of wall clock**.
   That is the design's central distinction demonstrated: a long test is not a
   silent process, and Family 5's steady-progress-at-10×-cost would not trip
   it. Verified to fire by pinning every cooperative-pool thread in a blocking
   `read(2)` inside an armed scope: the process aborted on the watchdog's own
   thread with a `/proc/self/task` table showing four
   `state=S wchan=anon_pipe_read` pool threads.

   No new environment variable: `CHICKADEE_WORKERTESTS_STALL_SECONDS` keeps
   its name and 300 s default even though it now covers two targets, because
   renaming it would silently drop an existing override.

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
  `api-tests-postgres` 257/330/351 s.
