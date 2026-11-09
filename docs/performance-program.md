# Performance program: weekly measurement, ratchets and production tuning

Status: plan, proposed 2026-11-09. Nothing in this page runs yet except where
it names an existing tool.

This page sets out how Chickadee measures its performance every week, how a
measured gain becomes a floor that later changes cannot fall below, and how to
tune the production setup. Production is one host for the server (blue-green)
and Postgres, and two runner machines of their own, which the maintainer
controls. It builds on
what exists: `chickadee-loadtest` ([load-testing.md](load-testing.md)), the
course-scale profile in [database-performance.md](database-performance.md),
`/admin/metrics` and the admin MCP tools
([operational-diagnostics.md](operational-diagnostics.md),
[admin-mcp.md](admin-mcp.md)), and the shrink-only ratchets described in
[fitness-functions.md](fitness-functions.md).

## Principles

1. **Ratchet on counts, report on time.** Wall-clock latency on a shared CI
   machine moves 20–50% from run to run, so a latency gate either flakes or is
   set so loose that it catches nothing. Counts do not move: SQL statements per
   request, rows hydrated per request, bytes of wasm, subprocesses per graded
   script. Counts become gates. Latency is recorded and trended, and a
   regression in latency is a question for a person, not a red build.
2. **A ratchet only tightens.** Each gated number has a baseline in the
   repository. A change that makes it worse fails. A change that makes it
   better prints a note to lower the baseline, as `PAGE_STYLE_BASELINE` does in
   `scripts/check-styles.sh`.
3. **Measure production, do not load it.** Production is measured read-only
   through the admin MCP. `chickadee-loadtest` never runs against production
   (its simulated runners claim real jobs).
4. **One layer per week.** Clean-up follows the measurement. Each week takes
   one layer of the stack, so every layer is visited once a month.
5. **No new environment variables.** A tuning knob on the runner is a CLI flag
   on `chickadee-runner`; anything else is derived or detected (root
   `CLAUDE.md`, "What Not To Do").

## The weekly cycle

Monday, so it lands in the same week as the weekly digest
(`.github/workflows/weekly-digest.yml`, Mondays 15:13 UTC).

| Step | What | Who runs it | Output |
|---|---|---|---|
| 1. Production snapshot | Read the week's production numbers through the admin MCP | Claude Code scheduled task on the maintainer's work machine (CI runs no model) | One row per metric appended to `docs/perf-log.md` |
| 2. Benchmark run | Release build, seeded course-scale database, fixed `chickadee-loadtest` profile, grading benchmark | New workflow `perf-weekly.yml` | JSON artifact; counts compared to baselines |
| 3. Digest | The benchmark's deltas and the production snapshot | `weekly-digest-render.sh`, one new section | Lines in the weekly digest issue |
| 4. Layer review | Profile and clean one layer (rotation below) | Maintainer with a Claude Code session | One PR per week that tightens at least one baseline or removes code |

### Step 1: the production snapshot

This runs as a Claude Code scheduled task on the maintainer's work machine,
with the `Chickadee_Admin` MCP connected, as the weekly dead-code review does
(`docs/dead-code-scan.md`). It is not set up yet. The task:

1. Calls the tools in the table below, read-only.
2. Appends one dated section to `docs/perf-log.md` on a branch, with the
   version from `get_deployment_info` and one row per number.
3. Compares each number with the previous section and lists the ones that
   moved more than 25%.
4. Opens a draft pull request with the log entry. The maintainer merges it, so
   the log is reviewed like any other change.

It never writes to production and never runs `chickadee-loadtest`.

These admin MCP calls answer the questions that matter for the week. Record
each as a row (date, version from `get_deployment_info`, value):

| Question | Tool | Number to record |
|---|---|---|
| Is the server fast on its hot paths? | `get_metrics_snapshot` → `hotPaths` | p50 / p95 / p99 of the runner poll and the status poll |
| Which statements cost the most? | `get_query_stats` | top 10 by total time; calls and mean time of each |
| Do students wait for a grade? | `get_metrics_snapshot` → `queueWait`, `execution` | queue wait p50 / p95; execution p50 / p95 |
| Are the runners full? | `get_metrics_snapshot`, `list_runners` | `peakUtilizationPercent`, `maxQueueDepth`, active jobs per runner |
| Does the setup cache work? | `get_runner_detail` | `cacheHitRatePercent` and `cacheHitSamples` per runner |
| Does the browser grader boot? | `get_browser_diagnostics` → `kernelBootFunnel` | count reaching each kernel phase; the drop-off between phases. Boot **time** is not recorded today: add a duration to the `kernel_phase` breadcrumb so this row can carry p50 / p95 |
| Is anything degrading? | `get_health_alerts`, `get_storage_usage` | firing rules; free disk |

The busiest hour of the week (a deadline) matters more than the average. Take
the p95 from the window that contains the week's largest `maxQueueDepth`.

`get_query_stats` reads `pg_stat_statements`, which accumulates since the last
reset. Record the deltas week over week, not the totals.

### Step 2: the benchmark run (`perf-weekly.yml`)

A new workflow, scheduled Mondays before the digest, with
`workflow_dispatch` and a `pull_request` trigger limited to its own files so a
change to it can prove itself (the pattern of `dead-code.yml`).
A report, never a gate, for its latency numbers; the counts it measures are
gated in the ordinary test lanes (see "Ratchets" below), not here.

1. Build `chickadee-server`, `chickadee-runner` and `chickadee-loadtest` in
   release mode.
2. Start Postgres 16 with the production settings from `docker-compose.yml`.
3. Seed the course-scale dataset. **This is missing today.** The 2026-11-09
   profile used one course with 300 students, 12 assignments, about 18,000
   submissions and log tables of 150,000–400,000 rows, but the seeder is not
   in the repository. Check in a `chickadee-loadtest seed` subcommand that
   writes that dataset deterministically (fixed random seed), so every week
   measures the same data.
4. Run three fixed profiles, each 120 s, each twice:
   - deadline poll: 50 runner slots at 1 s, 300 status pollers;
   - claim storm: 20,000 pending jobs, 100 runner slots;
   - instructor reads: grades CSV, assignment submissions page, student
     dashboard (a small scripted loop, added to the load tool).
5. Grading benchmark: one real `chickadee-runner --sandbox --max-jobs 2`
   grades a fixed batch per language (a small checked-in suite and submission for each of the seven languages; `Tests/Fixtures/generated-source/` has a starting point), cold
   cache then warm cache. Record per-job execution time and the time the
   runner spends outside the scripts (download, unzip, normalize, sandbox
   start, upload).
6. Write one JSON file: per route p50 / p95 / p99, statements per request
   (from `pg_stat_statements` before and after), server CPU seconds per 1,000
   requests (from `/proc` of the server process), per-language grading time.
7. Compare with the previous week's artifact and print the deltas. A delta
   larger than 25% on p95 that repeats on the second run is flagged in the
   digest.

Server CPU per 1,000 requests is the most useful time number: it is far less
sensitive to a noisy neighbour than latency, and it is what saturates first
(the 2026-11-09 profile saturated on CPU, not on the database).

## Ratchets to add

Each is a shrink-only baseline that runs in the ordinary CI lanes, so a PR
that regresses it fails before merge.

| Ratchet | How it is measured | Where it runs |
|---|---|---|
| SQL statements per hot-path request | An APITests suite that wraps the database with a statement counter and drives each hot route once against seeded rows: runner poll (idle and claim), status poll, student dashboard, submission page, assignment submissions page, grades CSV | `swift-tests.yml` |
| Statements that grow with the table | The same suite at two data sizes (10 rows and 1,000 rows); the count must be equal. A count that grows is an N+1 | `swift-tests.yml` |
| Rows hydrated per request | Same suite; the count of Fluent models decoded. Fluent hydration costs 40–60 µs per row on the event loop ([database-performance.md](database-performance.md)) | `swift-tests.yml` |
| Foreign keys without an index | Exists: `ForeignKeyIndexCoverageTests` | — |
| Runner wasm size | Exists: `scripts/check-runner-wasm-size.sh` gates on a generous ceiling (about 35% over today) and only prints the delta to `runner-size-baseline.txt`. Add a small allowance over the baseline instead, so growth needs a deliberate baseline edit | CI, as today |
| Vendored JupyterLite bytes per kernel | Sum of each kernel environment; shrink-only | `jupyterlite.yml` |
| Release binary size of server and runner | `stat` after the release build; shrink-only with a 2% allowance for a toolchain change | `docker-build.yml` |
| Dead declarations | Periphery count from `dead-code.yml`; shrink-only once the queue is near zero | `dead-code.yml` |
| SwiftLint structural thresholds | Lower `function_body_length`, `type_body_length`, `file_length` and `cyclomatic_complexity` in `.swiftlint.yml` whenever the largest offender is fixed | `format-lint` |
| `swiftlint:disable` count | Count of suppressions in `Sources/`; shrink-only | `format-lint` |

The first three are one test suite, and they are the core of the program: they
turn every finding in [database-performance.md](database-performance.md) into a
number that cannot quietly come back. Each new guard gets a fixture that shows
it failing (`scripts/check-guards.sh`, `scripts/check-guard-coverage.sh`).

## Layer rotation

One layer per week. In each, read the benchmark and the production snapshot
for that layer, profile its slowest path, and clean up. The output is one PR
that tightens at least one baseline or deletes code.

| Week | Layer | Profile | Clean-up targets |
|---|---|---|---|
| 1 | `RunnerCore` and `Worker` | Grading benchmark: time outside the scripts; sandbox start per script; cache hit rate | Periphery findings in the target; surviving mutants (`mutation-weekly.yml`); copies of the setup directory on a cache hit |
| 2 | `Core` and the database | `get_query_stats` top 10; `EXPLAIN (ANALYZE, BUFFERS)` on each; statement and hydration counts | Fluent reads that grow with the term → SQL aggregates or SQLKit rows; missing or unused indexes (`pg_stat_user_indexes.idx_scan = 0`) |
| 3 | `APIServer` routes and services | `perf` on the server during the load profiles; CPU per 1,000 requests by route | Work on the event loop that should not be there; repeated reads in one request; dead routes |
| 4 | Views, `Public/*.js`, JupyterLite | Kernel boot cost ([kernel-boot-cost.md](kernel-boot-cost.md)); page weight; `get_browser_diagnostics` | Unused JS and CSS; packages loaded at boot that could load on demand |

A fifth week in a month repeats whichever layer regressed most.

## Tuning the production setup (two runners)

The numbers below come from the code and `docker-compose.yml`. Each machine's
core count and memory decide the final values, so start by recording them.

### First, record the current state

On the server host:

```sh
nproc
free -g
docker compose ps
docker inspect --format "{{.Name}} {{.HostConfig.NanoCpus}} {{.HostConfig.Memory}} {{.HostConfig.PidsLimit}}" $(docker compose ps -q)
docker compose exec db psql -U chickadee -c "SHOW shared_buffers"
```

On each runner machine:

```sh
nproc
free -g
systemctl cat chickadee-runner
docker compose ps
```

Run whichever of the last two matches how that runner is started; the
`--max-jobs` value is on its command line.

Through the admin MCP: `list_runners` (each runner's `maxJobs` and version),
`get_metrics_snapshot` (queue wait and execution) for the last deadline, and `get_query_stats`.

### Runner concurrency (`--max-jobs`)

Grading is CPU-bound, and the default is `--max-jobs 4` per runner (eight
jobs across two runners). Under Compose the value comes from the existing
`RUNNER_MAX_JOBS` in that machine's `.env` (default 4); under systemd it is on
the `ExecStart` line of `chickadee-runner.service`.

The right value comes from two numbers at the last
deadline:

- Queue wait p95 high **and** runner CPU below about 80%: the runners are
  idle while jobs wait. Raise `--max-jobs`.
- Execution p95 rises with the number of active jobs: the jobs compete for
  CPU. Lower `--max-jobs`, or give the runners more cores.
- Both low: leave it.

Each runner has its own machine, so the starting point is `--max-jobs`
equal to that machine's cores, less one for the runner process, the
download and unzip work and the operating system. A test script that starts
several processes (a C++ build, `make -j`) uses more than one core; for a
course of those, start at half the cores.
Timeouts also count: a CPU-starved job can hit its time limit and turn into a
`timeout` the student did not cause. Check `jobStatusCounts.timeout` at each
deadline.

Each `--max-jobs` change has three dependent limits in the runner service,
and the comments in `docker-compose.yml` give each formula:

| Setting | Formula | At `--max-jobs 4` |
|---|---|---|
| `pids_limit` | `max-jobs × 128 + 64` | 576 |
| `mem_limit` | `max-jobs × 1024 MB + 512 MB`, and more than the tmpfs size | 4.5 GB |
| `tmpfs /tmp` size | the setup cache (16 prepared setups) plus one workspace per job | 1 GB today |

`mem_limit` and `cpus` are unset in `docker-compose.yml`. On a dedicated
runner machine that is safe for the server, which is elsewhere, but set
`mem_limit` anyway: without it a deadline that fills the job cgroups and the
tmpfs can push the machine into swap, and every job on it slows. Under
systemd, the matching settings are `MemoryMax=` and `TasksMax=` in the
unit.

### Two machines, one queue

Both runners poll the same queue, so the server sends work to whichever asks
first. If the two machines differ in cores, give each a `--max-jobs` that
matches its own cores; the faster machine then takes more jobs on its own.
Compare the two in `list_runners` and `get_runner_detail` each week: active
jobs, execution p95 and cache hit rate per runner. A runner whose execution
p95 is clearly higher than the other's on the same assignments has too many
jobs for its cores.

Each runner keeps its own setup cache, so the first job of each assignment
is a cache miss once per runner. The cache lives in `/tmp`, so a runner
restart empties it. With two runners that is two misses per assignment per
restart, which costs little.

Under Compose, updating a runner drains it (`stop_grace_period: 10m`): it
finishes its jobs while the other keeps grading. Update the two one at a time, never together, and never in the hour
before a deadline.

### The server host

With the runners elsewhere, the server host holds the server and Postgres
only, and during a blue-green cutover two server processes. The server
saturated on CPU in the 2026-11-09 profile, not on the database, so the
server's p95 under load is the number to watch here; if it rises with
runner polls, `hotPaths` shows which route.

### Postgres

The compose file sets `shared_buffers=256MB`, `max_connections=200` and the
`pg_stat_statements` options, and leaves the rest at the defaults. For
a dedicated host with `R` GB of memory available to Postgres:

| Setting | Value | Why |
|---|---|---|
| `shared_buffers` | 25% of R | the working set of a term fits |
| `effective_cache_size` | 60–70% of R | the planner knows the page cache exists |
| `random_page_cost` | 1.1 | SSD storage; the default 4 steers the planner away from indexes |
| `work_mem` | 16MB | the grade fold and sorts stay in memory; it applies per sort per connection, so keep it modest |
| `max_connections` | at least `DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP × server cores × server processes`, plus headroom | blue-green runs two servers during a cutover |
| autovacuum on `request_metrics`, `user_activity_events`, `audit_log`, `runner_snapshots` | `autovacuum_vacuum_scale_factor=0.05` per table | these take a row per request and are pruned in bulk |

These go on the `command:` line of the `db` service, as the existing settings
do, so they need no new environment variable. Change one at a time and
compare `get_query_stats` the following week.

### Runner-side caches

- `TestSetupCache` holds 16 prepared setups. A deadline week usually has two
  or three active assignments, so 16 is enough unless the hit rate in step 1
  says otherwise. If it does, add a `--test-setup-cache-entries` flag. It does
  not exist yet: 16 is `TestSetupCache.defaultMaxEntries`. It must be a CLI
  flag, not a variable.
- A cache hit **copies** the prepared directory into a fresh workspace. For
  large setups (datasets) that copy is measurable. The week-1 profile should
  say whether a hard-link or reflink copy is worth it.

### Retention

The log tables grow with traffic, and the 2026-11-09 profile ran with
150,000–400,000 rows in each. The defaults (`JOB_METRIC_RETENTION_DAYS=30`,
`RUNNER_SNAPSHOT_RETENTION_DAYS=30`, `AUDIT_LOG_RETENTION_DAYS=90`) are
already set; check in step 1 that pruning runs (the "Diagnostics prune"
lease) and that the table sizes are flat week over week.

## Order of work

1. Record each runner machine's cores, memory and `--max-jobs`, and the
   server host's cores and memory. Set `--max-jobs` on each runner from its
   cores, then its `pids_limit` and `mem_limit` (or `TasksMax=` and
   `MemoryMax=`) to match.
2. Add the statement- and hydration-count suite with its baselines. This is
   the ratchet that pays for itself first.
3. Check in the deterministic seeder.
4. Add `perf-weekly.yml` and the digest section.
5. Apply the Postgres settings one at a time, a week apart, and read each
   result in the production snapshot.
6. Set up the production snapshot as a scheduled task on the maintainer's
   work machine.
7. Start the layer rotation.
8. Make the remaining ratchets shrink-only as each one's first clean-up lands.

## Decisions

Made:

- The two runners are separate machines that the maintainer controls.
- The production snapshot runs as a Claude Code scheduled task on the
  maintainer's work machine. It is set up after this plan lands.

Open:

- Whether `docs/perf-log.md` is the right home for the weekly numbers, or a
  pinned issue updated each week. The plan assumes the file.
