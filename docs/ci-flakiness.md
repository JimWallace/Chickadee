# CI flakiness — state of knowledge (2026-07-02)

Handoff document for the flakiness work. Everything below was observed
first-hand on 2026-07-02 while landing PRs #1138–#1142 (the UI-guards
series), plus workflow-history queries. The headline: **on an afternoon of
loaded runners, an average PR had roughly a coin-flip chance of at least one
flaky-job failure per full CI run**, and the only re-kick available to a bot
(a new commit SHA) re-rolls *every* die at once.

The four runs of PR #1138 are the cleanest dataset because the tree was
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

## Family 1 — `WorkerTests.stdoutIsCaptured()` stall (issue #1139)

**Symptom.** Two shapes of the same stall: (a) the test fails its stdout
expectation after almost exactly 60 s; (b) the whole job wedges inside the
`WorkerTests` suite until the job-level 20-minute kill. Observed
pass / fail / pass / hang across four runs of one tree — ~50 % that
afternoon. Normal green runtime for the job is ~90 s–2 min.

**Where.** `Tests/WorkerTests/WorkerTests.swift:83` — the test runs a real
`/bin/sh` subprocess and asserts its stdout is captured.

**Hypothesis.** A subprocess + pipe-drain race that only bites on loaded
runners: if stdout is drained only after `waitUntilExit` (or vice versa), a
slow-to-spawn/slow-to-exit child plus a filling pipe buffer deadlocks; the
60 s shape smells like an internal wait that expires with the pipe never
seeing EOF.

**Attack order (also in #1139).**
1. Reproduce under load — run the suite in a loop with `stress-ng` beside
   it (or in CI via a temporary matrix job) until the stall reproduces.
2. Inspect the test's read pattern vs. the worker's own bounded-capture
   machinery (`ScriptRunner` already solves exactly this problem for
   production code — the test harness should reuse it, not re-roll it).
3. Whatever the root cause, add a **per-test timeout with a clear message**;
   a 60 s silent stall or a 20-minute job kill is the worst possible
   failure UX.

This is the best first target: fully deterministic surface (no browser), a
filed issue with evidence, and it double-charges every PR because
`worker-tests` runs in the required Swift pipeline.

## Family 2 — webkit grading hang (`grading-probe (webkit)`, `hangs=N/12`)

**Symptom.** The grading-hang probe (`grading-hang-probe.yml`) boots the
real server + notebook page 12 times per engine and counts grading hangs;
webkit intermittently reports `hangs=1/12` and the job fails (threshold is
zero). Chromium passed 12/12 in the same runs.

**History** (`list_workflow_runs` on `grading-hang-probe.yml`): failures on
unrelated branches on 2026-06-26 (×3, different PRs) and 2026-07-02; green
otherwise. So a low, persistent background rate that predates this week.

**Context.** This probe *exists* to monitor a real historical bug — see
`docs/exec-hang-investigation.md` and the boot-funnel telemetry work
(v0.4.351+ digest). The probe is doing its job: the hang still exists at
low frequency on webkit under CI load. Two directions, not mutually
exclusive:
1. **Root cause** — continue the exec-hang investigation with the probe's
   breadcrumb output (`grading breadcrumbs:` lines give per-phase timings
   for the hung iteration).
2. **Gate policy** — decide whether a monitoring probe should gate PRs at
   `hangs=0/12`. Options: keep it PR-gating but tolerate `hangs<=1/12`
   (alert at higher), or move webkit to the nightly schedule only and keep
   chromium PR-gating. Either needs a deliberate decision — the zero
   threshold is what keeps pressure on the real bug.

## Family 3 — webkit editor smoke, post-idle execute (`smoke (webkit)`)

**Symptom.** The editor-smoke selftest's post-idle probe (idle, then run a
cell) fails: `post-idle execute passed? 0 (want 1)` — kernel never runs the
expression. One failure in the last 25 runs of `editor-smoke.yml` (24/25
green; this branch alone passed it 4× the same day). Same exec-hang class
as Family 2, different harness.

**Note.** `smoke` failing turns `editor-smoke-gate` red, and that IS the
required check — so this family, though rarest, is the one that hard-blocks
merges when it fires.

---

## Structural problems (independent of any single test)

1. **A bot's only re-kick is a new SHA.** Agents (and anyone without the
   Actions UI) re-trigger by pushing an empty commit, which re-runs the
   *entire* pipeline and re-rolls every flaky die — the PR #1138 sequence
   (three different flakes in four runs) is what that looks like.
   Maintainers should prefer the Actions UI's **"Re-run failed jobs"**,
   which re-rolls only the failed die. Possible improvements:
   - a comment-triggered rerun workflow (e.g. `/rerun-failed` via
     `workflow_dispatch` + `gh run rerun --failed`) usable by bots;
   - automatic retry inside the known-flaky steps (e.g. wrap the probe or
     the worker-tests invocation in one bounded retry, with the retry
     *logged loudly* so the flake rate stays visible rather than hidden).
2. **Compounding probability.** A UI-touching PR currently rolls at least
   three dice per run (worker-tests, grading-probe webkit, smoke webkit).
   Even at individually modest rates the composite failure rate on a loaded
   afternoon was ~50 %. Fixing Family 1 removes the biggest term.
3. **Silent-stall failure shapes burn the most wall-clock.** Family 1(b)
   holds a runner for 20 minutes before failing. Per-test/per-phase
   timeouts with immediate, descriptive failures make every retry loop
   ~6× cheaper.

## Suggested attack order

1. **#1139** (`stdoutIsCaptured`) — deterministic, filed, highest PR tax.
2. **Per-test timeout hygiene** in WorkerTests generally (cheap, bounds all
   future stalls).
3. **Rerun ergonomics** — comment-triggered `rerun failed jobs`, so no one
   ever burns a full pipeline on a re-roll again.
4. **Exec-hang root cause** (Families 2+3 share it) — continue from
   `docs/exec-hang-investigation.md` with the probe breadcrumbs; only after
   that, revisit the probe's PR-gating threshold if the residual rate is
   accepted as ambient.

## Evidence index

- Issue #1139 — `stdoutIsCaptured` flake, with the four-run table.
- PR #1138 — the four byte-identical runs (28586988643, 28588059980,
  28588705591, 28589351648).
- `docs/exec-hang-investigation.md` — the webkit exec-hang root-cause work.
- `grading-hang-probe.yml` run history — background failure rate on
  unrelated branches (2026-06-26 ×3).
- `editor-smoke.yml` run history — 24/25 green over the trailing window.
