# CI flakiness — known families

**Open: Families 2, 3, 4 and 7.** These can still make a check red, and the
cause is not fixed in this repository. **Mitigated: Family 5.** It is closed
for monitoring since 2026-09-28, but nobody found its cause. **Fixed: Families
1 and 6.**

Read this file before you diagnose a red check on a PR that did not touch the
failing area. Each family keeps its original number, because code comments
and workflows cite "Family 5" and "Family 7". The investigation history, with
the evidence for each statement here, is in
[archive/ci-flakiness-history.md](archive/ci-flakiness-history.md).

`ci-triage.yml` and `nightly-failure-notes.yml` give this file to a model.
The model reads this introduction and the heading of each `## Family`
section. Keep one `## Family N` heading for each family.

## The families

| # | Family | Status | Tells (how to recognize it in a log) | What to do |
|---|---|---|---|---|
| 1 | `WorkerTests.stdoutIsCaptured()` stall (#1139) | fixed | Shape (a): the test fails after about 60 s with empty stdout. Shape (b): `worker-tests` hangs to its 20-minute kill and reads `cancelled`. | The cause is gone. A new stall with this shape is a different bug. Read Family 6 first. |
| 2 | webkit grading hang, `grading-probe (webkit)` `hangs=N/12` | open (contained by a tolerance) | `hangs=1/12` on webkit; a `::warning` "AMBIENT FLAKE TOLERATED" on a PR run. The breadcrumb trail stops before `suite_done`. | A tolerated warning is not your diff. Read the breadcrumbs before you decide. |
| 3 | webkit editor smoke, post-idle execute, `smoke (webkit)` | open (contained by a retry) | `post-idle execute passed? 0 (want 1)`; a `::warning` "FLAKE RETRY". | Not your diff when one retry passes. One retry is automatic, and a second failure fails the gate. Then check the tells before you re-run. |
| 4 | `worker-tests` SIGABRT from the wedge watchdog (URLSession cancel deadlock, upstream) | open (mitigated first-party) | `worker-tests` fails (not `cancelled`) after about 5 minutes with `exited with unexpected signal code 6`. The dump has `WedgeWatchdog.abortWedgedProcess` and a `CancelState.cancel` / `withStatusRecordLock` pair. | Not your diff. One `/rerun-failed`. For a mutation shard, re-run that shard. |
| 5 | `api-tests` killed at its ceiling during a throughput collapse | mitigated (closed for monitoring) | `api-tests` reads `cancelled` at its 25-minute ceiling. Tests still complete at the tail of the log. `api-tests-postgres` passed on the same commit. | Not your diff if the tells match. One `/rerun-failed`. Read the `[ci-pressure]` lines. |
| 6 | `worker-tests` cancelled at its ceiling after the move to resolute | fixed | `worker-tests` reads `cancelled`. `[ci-pressure]` shows `scopes=0.0/min` with `self cpu=0.0%`. Some `WorkerDaemonTests` record "Time limit was exceeded". | It should not recur. If it does, read the printed wedge dump. |
| 7 | `build` exits 139 as Swift Build starts planning (libdispatch, upstream) | open (upstream bug; in-job retry) | Step `Build all targets and tests` red within about 90 s. Exit 139. The last build line is `[Planning 1 / N]`. `DispatchWorker` crashed in `_dispatch_event_loop_drain`. A `::warning` "Family 7 retry" on a green job is one absorbed hit. | Not your diff: nothing compiled. One `/rerun-failed`. Never read the diff for it. |

## Before you chase a red check

Do these steps in this order.

1. **Read the `ci-triage.yml` comment, but do not trust it alone.** It is a
   first reading, not evidence. Check the tells of the family that it names
   before you spend the one re-run.
2. **Ask if the diff can reach the failing job.** For `api-tests`, does the
   diff touch `Sources/APIServer/` or `Tests/APITests/`?
3. **Find the shape of the failure.** A job that reads `cancelled` at its
   ceiling is Family 5 or Family 6. A job that fails after about 5 minutes
   with signal 6 is Family 4. A `build` step that exits 139 is Family 7 only
   if the full signature matches.
4. **For a `cancelled` job, examine the tail of the log.**
   - Were tests still *completing* at the tail? A wedge stops. A collapse
     (Family 5) continues to finish tests slowly.
   - Did `api-tests-postgres` pass on the same commit? It runs the same
     target.
   - What do the `[ci-pressure]` lines say? `scopes=0.0/min` with
     `self cpu=0.0%` is a stop (Family 6). A HINT line names its own cause.
   - On `main`, make sure that the `Run APITests` step ran to the budget.
     With `cancel-in-progress: false`, GitHub cancels older pending runs. A
     run that GitHub cancelled before any job started is bookkeeping, not a
     ceiling kill.
5. **Do not use per-test or per-suite durations from a Swift Testing log.**
   Swift Testing starts the clock of a test when it *schedules* the test, not
   when the test gets a parallelization slot. A healthy `api-tests` run has a
   median test duration of about 80 s. Every suite ends at about the total
   time of the run. A "slow test" in that log is an artifact.
6. **For a `build` job that exits 139**, look for all three parts of the
   signature: red within about 90 s, `[Planning 1 / N]` as the last build
   line, and `DispatchWorker` in `_dispatch_event_loop_drain`. That is Family
   7, an upstream SwiftPM crash. Answer it with one `/rerun-failed`. A crash
   in `swift-frontend` after `Compiling` lines is a compiler crash. That one
   is the PR's to find.
7. **Re-run with `/rerun-failed`** on the PR, or with `rerun-failed-jobs` on
   the run. **Never push an empty commit.** An empty commit runs every flaky
   job again and makes the shared build cache key not valid.
8. **If no family matches, the failure is real or it is a new family.** To
   add a family, add a row and a `## Family N` section here. `ci-triage.yml`
   reads this file from `main` on each run, so it learns the new family at
   once.

## Family 1 — `WorkerTests.stdoutIsCaptured()` stall (issue #1139) — ROOT-CAUSED & FIXED

The cause was a fork-safety bug in the Linux script launcher of the worker.
The child process called functions that are not async-signal-safe between
`fork()` and exec, and deadlocked under load. Two shapes followed:

- **(a)** The child deadlocked after `setsid()`. The test failed at about
  60.3 s with empty stdout.
- **(b)** The child deadlocked before `setsid()`. The group kill missed, an
  unbounded `waitpid` held a thread, and the job hung to its 20-minute kill
  as `cancelled`. `rerun-failed.yml` includes `cancelled` runs for this shape.

The hand-written launcher is gone. Every worker subprocess now goes through
`executeScriptLaunch` (`Sources/Worker/ScriptExecution.swift`), built on
swift-subprocess. The replacement must still obey these rules:

- Isolate the session before any other step can fail.
- Kill the whole process group, not only one pid.
- Never do an unbounded wait on a cooperative-pool thread.
- Replace the parent environment. Do not add to it.

Subprocess-spawning `WorkerTests` suites carry `.timeLimit(.minutes(3))`. A
stall then fails as a named test, not as a silent 20-minute job kill.

## Family 2 — webkit grading hang (`grading-probe (webkit)`, `hangs=N/12`) — CONTAINED, root cause open

**Tells.** The `grading-probe` job of `browser-probes.yml` boots the server
and the notebook page 12 times for each engine. It counts iterations that did
not render a result. Webkit sometimes reports `hangs=1/12`.

**Gate policy.** Chromium: hard zero on every run. Webkit: `hangs<=1/12` is
tolerated on `pull_request` runs, with a loud `::warning`. Dispatch and
scheduled runs keep the hard zero. The probe runs weekly (Monday 04:17 UTC).

**`hangs=N/12` is not always a hang.** The counter includes a server-side 500
after a healthy grade. Read the breadcrumb trail first:

- If the trail stops **before** `suite_done`, it is this family.
- If the trail reaches `suite_done` and then `submit_failed` with a 500, it is
  a server-side failure of the result POST. That is not this family. Two such
  causes are fixed (side effects after the result save run best-effort, and
  `withWriteLockedTransaction` opens the attempt-number transaction with
  `BEGIN IMMEDIATE`, #1919). A new one is a new bug. `run-smoke.sh` prints
  the error-level lines of the whole server log before the tail. Read them.

**Chromium is rarer, not immune.** One chromium hang (2026-08-04) did not
reproduce on a re-run. Chromium keeps its hard zero, so a chromium hang is
loud. Do not treat it as noise.

**Where a new hang starts.** The Pyodide-era trail in
`docs/archive/exec-hang-investigation.md` describes code that no longer
ships. Start from the five classes that the probe reports (`deadlock`,
`bootStall`, `dialogSteal`, `lostDispatch`, `webkitWasmCrash`) and the
enriched beacons of issue #1049. A fix must turn the hard-zero dispatch and
scheduled runs green.

## Family 3 — webkit editor smoke, post-idle execute (`smoke (webkit)`) — CONTAINED, same root cause as Family 2

**Tells.** The editor-smoke selftest reports `post-idle execute passed? 0
(want 1)`. The kernel does not run the expression. `smoke` feeds
`editor-smoke-gate`, which is a required check.

**Containment.** The webkit legs of `smoke` (the selftest and the
notebook-page e2e) get exactly one retry, with a `::warning` "FLAKE RETRY". A
second failure fails the gate. Chromium legs are strict: a chromium failure
is real the first time.

**Watch the warning rate (Families 2 and 3).** `flake-telemetry.yml` counts
the tolerated `::warning` annotations and the red probe runs each week, and
posts the count. If the count trends up, the ambient rate is rising. Then
revisit the tolerance, in either direction.

## Family 4 — `worker-tests` SIGABRT via the wedge watchdog (URLSession cancel deadlock) — MITIGATED first-party; root cause still upstream

**Tells.** `worker-tests` fails (not `cancelled`) after about 5 minutes with
`exited with unexpected signal code 6`. The crashing thread is
`WedgeWatchdog.abortWedgedProcess`. That is the watchdog doing its job. Look
elsewhere in the dump for a `CancelState.cancel` / `withStatusRecordLock`
pair. That pair is this family.

**Cause.** A lock-order deadlock in swift-corelibs-foundation's `URLSession`
on Linux. It occurs when a task is cancelled while its download completes.
The prepare phase now awaits both fetches (`fetchJobArtifacts` in
`RunnerDaemon+JobPreparation.swift`), which removes the common trigger. Other
cancellation sites remain on purpose, for example
`TestSetupCache.detachWaiter`.

**Handling.** Re-run the failed job: `/rerun-failed` on the PR, or
`rerun-failed-jobs`. In the weekly mutation sweep, a shard lost to this is not
a failed sweep. Read the other shards and re-run that one.

**Decision (2026-09-15): accept the rate.** Do not change the runner to avoid
this bug. Do not replace the async `URLSession` calls with a
completion-handler wrapper: that replaces the deadlock with a `fatalError`
crash in `TaskRegistry`. Open the decision again if one of these occurs:

- The rate rises above about one shard per sweep, or it hits `worker-tests`
  on ordinary PRs.
- It reaches a runner in production.
- swift-corelibs-foundation fixes either half of the bug. Then take the new
  Foundation.

## Family 5 — `api-tests` killed at its ceiling during a throughput collapse — MITIGATED, closed for monitoring; cause unknown

**Tells.** `api-tests` reads `cancelled` at its 25-minute ceiling, and
`swift-tests-gate` fails with `jobs not successful: api-tests`. It looks like
a wedge, but it is not one. The job still finishes tests when GitHub kills
it. Use steps 2 to 5 of the checklist above. Of the three tells that the
original entry used, only "tests still complete at the tail" is evidence. The
other two (similar suite totals, large per-test durations) are artifacts of
Swift Testing and are true of every run.

**What changed.** Two changes halved the cost of the lane, and the collapse
did not occur in 88 `main` runs after them:

- The `api-tests` and `api-tests-postgres` containers mount `/tmp` as a tmpfs
  (`--tmpfs /tmp:rw,exec,size=2g`). `exec` is necessary: the suite writes
  scripts there and runs them.
- Test applications no longer run all migrations each time. The sqlite lane
  copies a migrated template file. The postgres lane recycles migrated schemas
  from `MigratedPostgresSchemaPool`.

The cause of the collapse is not known. It stopped after the cost went down.
The open leads are fsync latency variance, something inside the test process,
CPU steal from a co-tenant, and a subprocess storm (21 of 376
`Tests/APITests/` files spawn a process and name a real interpreter).

**The instrument.** `StarvationRecorder` (`Tests/TestSupport/`) writes one
`[ci-pressure]` line to stderr every 30 seconds. Each line has the last window
and the totals since arming, because a ceiling kill runs no exit handler. It
arms from the `WedgeWatchdog` seam. `CHICKADEE_WORKERTESTS_STALL_SECONDS=0`
stops the watchdog abort but does not stop the recording.

| field | non-zero means |
|---|---|
| `steal` | the hypervisor gave the CPU to another tenant. Nothing here can fix it. |
| `throttled` | the kernel stopped the container for its CPU quota. |
| `io_full` | every task on the machine was blocked on disk. |
| `mem_full` | the same, for memory reclaim. |
| `kids` much larger than the CPU count | a subprocess storm. |
| `busy` high, `self cpu` low | something else in this VM uses the machine. |

`scopes/min` is the count of finished test bodies. It is the throughput.

**Rules that stay.**

- `WedgeWatchdog` cannot detect this family. It measures silence, and a slow
  lane is never silent.
- Raising the ceiling is not the lever. The median is the lever.
- Do not shard `api-tests` without a guard that proves the union of the
  shards is the whole target. Swift Testing has no shard primitive, and a
  suite outside every filter would never run.
- `repeat-test.yml` cannot reproduce a lane collapse. It loads the machine
  less than a full lane does. Read its `[ci-pressure]` lines all the same.
- **A guard pointed at a mechanism by name is a guard that changing the
  mechanism silently empties.** (This lesson came from attack note 5, the
  template change.)

**Reproduce `APITests` locally** with
`SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4`, as CI does. Without that
limit, the target crashes with SIGSEGV locally, with many AsyncKit
"Connection request timed out" errors. That crash looks like a regression in
your change, but it is not one.

## Family 6 — `worker-tests` cancelled at its ceiling after the move to resolute — ROOT-CAUSED & FIXED

**Tells.** `worker-tests` runs to its 20-minute `timeout-minutes` and reads
`cancelled`. Some `WorkerDaemonTests` record "Time limit was exceeded"
(always with `hungMakeStepIsKilledAtTheConfiguredTimeout` and
`workerDaemonReportsFallbackFailureWhenFinalReportFails`). The
`[ci-pressure]` lines show 0 % CPU from about one minute in. Nothing else
finishes. It is the opposite of Family 5: Family 6 stops completely.

**Two causes, both fixed.**

1. Foundation's `Process` leaked its exit-signal socket into sibling
   children, so `LocalHTTPTestServer.stop()` waited forever. The test server
   now launches through swift-subprocess, and `stop()` does not wait.
2. glibc 2.41 and later holds an abort lock during `posix_spawn`. A
   swift-subprocess child made by `clone3` could inherit that lock held and
   block before exec. `Package.swift` pins swift-subprocess to the fork
   `JimWallace/swift-subprocess`, branch `chickadee/abort-lock-fix`. Return to
   upstream when a release has an equal fix. The upstream report is
   [swiftlang/swift-subprocess#375](https://github.com/swiftlang/swift-subprocess/issues/375),
   and #1597 has the steps to move back. `SubprocessSpawnRaceTests` pins it.

**Handling if it reappears.** The watchdog writes its thread table to
`/tmp/chickadee-wedge-dump-<pid>.txt`. The `worker-tests` lane prints that
file in the step "Print the wedge watchdog dump", on failure or cancel. The
test step has its own 15-minute limit, so there is time for that print. Read
the dump first. A pool thread in `futex` or `pipe_read`, with a `syscall=`
that names a `read` or a `wait`, is this shape.

Do not add a Foundation `Process` again. `scripts/no-foundation-process.sh`
fails `format-lint` on one. Use `SupervisedProcess` for a long-lived child.
Use the one-shot Subprocess helpers in
`Tests/TestSupport/InterpreterSpawn.swift` in tests.

## Family 7 — `build` exits 139 as Swift Build starts planning (libdispatch epoll use-after-free, upstream) — UPSTREAM BUG, RE-RUN ONCE

**Tells.** The `build` job fails in its `Build all targets and tests` step
about 85 s after the step starts. The log shows `Segmentation fault (core
dumped)` and `Process completed with exit code 139`. Nothing is compiled. The
last build line is `[Planning 1 / N]`, and the next line is `*** Signal 11:
Backtracing from ...`. The backtrace shows thread `DispatchWorker` crashed in
`_dispatch_event_loop_drain` in `libdispatch.so`. The four test lanes are
skipped and `swift-tests-gate` reads `failure`.

**Cause.** SwiftPM 6.4 made Swift Build the default build engine. During
planning, its tool discovery triggers a use-after-free in libdispatch's epoll
backend. It is SwiftPM that crashes, not the compiler and not a test. Upstream
reports, all open:
[swiftlang/swift-build#1786](https://github.com/swiftlang/swift-build/issues/1786),
[swiftlang/swift-corelibs-libdispatch#949](https://github.com/swiftlang/swift-corelibs-libdispatch/issues/949),
[swiftlang/swift#87033](https://github.com/swiftlang/swift/issues/87033).
The release image and the coverage run use `--build-system native`, so they
do not see it.

**In-job retry (#1698).** `scripts/ci-build-retry.sh` runs
`swift build --build-tests`. It runs it once more only when the first attempt
exited 139 with `_dispatch_event_loop_drain` in its output. Any other failure
fails on the first attempt. A hit prints a `::warning` "Family 7 retry" and
the job stays green. Two hits in one attempt fail the job.
`scripts/ci-build-retry.sh --self-test` runs in `format-lint`.

**Handling when the job is red.**

1. Comment `/rerun-failed` on the PR, or call `rerun-failed-jobs` on the run.
   Nothing in the diff was compiled, so the diff cannot be the cause. Do not
   push an empty commit.
2. If the next attempt dies with the same signature, re-run again. A repeat
   is not a reason to read the diff.
3. Any other crash in that step is not this family. That includes a segfault
   in a different thread or frame.

**Remove the retry** when the pinned toolchain carries an upstream fix. The
"try the build without each workaround" step of the semi-annual upgrade
(`docs/swift-toolchain-upgrades.md`) is the place to do it.

**Not a stall and not a test.** The job is red in under two minutes, with a
backtrace. No test binary exists yet. The `[ci-pressure]` lines and the wedge
watchdog never run.

## Structural problems → current state

The CI tools that exist because of these families:

- **Automatic triage.** When a CI workflow fails, `ci-triage.yml` gives the
  failed log and this file to a small model. It posts one comment: a known
  family (with the tell that matched), a real failure (with its first error),
  an infrastructure death, or "unclear". It never re-runs a job.

1. **A bot's only re-kick was a new SHA.** Fixed. Comment `/rerun-failed` on
   a PR (`rerun-failed.yml`, OWNER, MEMBER and COLLABORATOR only). It re-runs
   only the failed and cancelled runs for the current head SHA through
   `rerun-failed-jobs`, and keeps every green result.
2. **Compounding probability.** A UI PR used to roll several flaky jobs on
   each run. The Family 1 fix and the webkit tolerances removed most of that.
3. **Silent stalls.** Fixed at three layers: bounded waits in the runner,
   `.timeLimit` on suites that can stall, and the job-level `timeout-minutes`
   as the last guard. `WedgeWatchdog` aborts with a thread table after 300 s
   of silence (`CHICKADEE_WORKERTESTS_STALL_SECONDS`; 0 stops the abort).
4. **A rare failure had no reproduction tool.** Fixed. `repeat-test.yml`
   (Actions tab, "Repeat a test") runs one `--filter` selection up to N times
   on the CI image and stops at the first failure. It reproduces the flake of
   one test, not the load of a full lane.

## History

The full investigation of each family, the measurements, the rejected options
and the evidence index are in
[archive/ci-flakiness-history.md](archive/ci-flakiness-history.md).
