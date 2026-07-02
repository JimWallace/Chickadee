# CI flakiness — state of knowledge (2026-07-02, updated after the #1139 fix)

Handoff document for the flakiness work. The first snapshot (earlier on
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

## Family 2 — webkit grading hang (`grading-probe (webkit)`, `hangs=N/12`) — CONTAINED, root cause open

**Symptom.** The grading-hang probe (`grading-hang-probe.yml`) boots the
real server + notebook page 12 times per engine and counts grading hangs;
webkit intermittently reports `hangs=1/12`. Chromium passes 12/12 in the
same runs. Failures observed on unrelated branches 2026-06-26 (×3) and
2026-07-02 — a low, persistent background rate that predates that week.

**Context.** The probe *exists* to monitor a real historical bug — see
`docs/exec-hang-investigation.md` and the boot-funnel telemetry work. The
hang still exists at low frequency on webkit under CI load.

**Gate policy (decided & shipped).** Chromium: hard zero everywhere.
Webkit: `hangs<=1/12` tolerated on `pull_request` runs with a loud
`::warning` annotation; `workflow_dispatch`/scheduled runs keep the hard
zero, so the probe remains the regression guard a real fix must turn green
and the ambient rate stays measured rather than silently absorbed.

**Root cause** remains the exec-hang investigation's to close — continue
from the probe's `grading breadcrumbs:` per-phase timings on a hung
iteration.

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
   `docs/exec-hang-investigation.md` with the probe breadcrumbs. The
   dispatch/scheduled hard-zero runs of `grading-hang-probe.yml` are the
   fix's acceptance test.
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
   in when those files are next touched.

## Evidence index

- Issue #1139 — `stdoutIsCaptured` flake, with the four-run table.
- PR #1138 — the four byte-identical runs (28586988643, 28588059980,
  28588705591, 28589351648).
- Stress repro (this doc, Family 1) — old 8/200 vs fixed 0/3000.
- `docs/exec-hang-investigation.md` — the webkit exec-hang root-cause work.
- `grading-hang-probe.yml` run history — background failure rate on
  unrelated branches (2026-06-26 ×3).
- `editor-smoke.yml` run history — 24/25 green over the trailing window.
