# Operational Diagnostics

Chickadee records backend-only observability for submission jobs, runner
activity, and server request timing. There is still no dashboard UI in this
layer; operators use structured logs, SQLite data, and one protected JSON
endpoint.

## What Is Collected

### Durable job metrics

Stored in `job_execution_metrics`, with one row per submission job milestone.

Captured fields include:

- `submission_id`
- `job_id`
- `test_setup_id`
- `course_id`
- `assignment_id`
- `user_id`
- `runner_id`
- `kind`
- `attempt_number`
- `enqueued_at`
- `assigned_at`
- `started_at`
- `completed_at`
- `queue_wait_ms`
- `execution_ms`
- `total_processing_ms`
- `final_status`
- `tests_passed`
- `tests_failed`
- `tests_errored`
- `tests_timed_out`
- `skipped_count`
- `free_disk_mb_at_start` — free space on the runner's temp filesystem when the
  job was accepted, in megabytes
- `free_disk_mb_at_end` — free space at end of execution, before workspace
  cleanup; worst-case reading for the job
- `workdir_peak_bytes` — total bytes in the per-job workspace just before
  cleanup; proxy for peak disk working-set

Definitions:

- `queue_wait_ms = assigned_at - enqueued_at`
- `execution_ms = completed_at - started_at`
- `total_processing_ms = completed_at - enqueued_at`
- Disk readings are best-effort: the runner records them only when it can
  query the filesystem; missing readings are stored as `NULL`, so any
  threshold query should `COALESCE`/`IS NOT NULL`-guard.

`final_status` is one of:

- `passed`
- `failed`
- `error`
- `timeout`

The older `submission_diagnostics` table is still written for compatibility with
existing diagnostics/admin surfaces.

### Runner liveness snapshots

Stored in `runner_snapshots`.

Captured fields include:

- `runner_id`
- `recorded_at`
- `active_jobs`
- `max_jobs`
- `available_capacity`
- `hostname`
- `runner_version`
- `last_poll_at`
- `last_heartbeat_at`
- `server_assigned_job_count_since_start`

When a timestamp or metric is unavailable, the corresponding column is left
null. Observability writes are best-effort and must not block grading.

### Request timing

Stored in `request_metrics`.

Captured fields include:

- HTTP method
- request path
- request kind (`job_dispatch`, `result_writeback`, `api`, `web`)
- HTTP status code
- request start / end timestamps
- request duration in milliseconds
- `submission_id` when available
- `worker_id` when available

This makes it possible to inspect server-side latency for worker dispatch,
result write-back, and general API traffic over time.

## Structured Logs

Server-side structured log events include:

- `submission_accepted`
- `job_enqueued`
- `runner_polled`
- `runner_heartbeat`
- `runner_profile_registered`
- `runner_profile_updated`
- `assignment_requirements_loaded`
- `compatibility_check_passed`
- `compatibility_check_failed`
- `no_compatible_runner_available`
- `job_assigned_to_compatible_runner`
- `job_assigned`
- `result_received`
- `job_finalised`
- `assignment_result_summary`
- `test_result_summary`
- `job_recovery`

Runner-side structured log events include:

- `runner_startup`
- `runner_configuration`
- `server_connection_lost`
- `server_connection_restored`
- `heartbeat_retry_scheduled`
- `network_retry_scheduled`
- `poll_cycle_start`
- `poll_cycle_end`
- `job_accepted`
- `test_execution_start`
- `test_execution_end`
- `result_submission_succeeded`
- `result_submission_failed`
- `local_execution_error`
- `timeout`
- `runner_shutdown`
- `job_stage_timings` — emitted at end-of-job with the wall-clock totals plus
  per-stage millisecond fields (`workdir_setup_ms`, `submission_download_ms`,
  …, `test_execution_ms`, `cleanup_ms`)
- `job_disk_usage` — emitted at end-of-job with `free_disk_mb_at_start`,
  `free_disk_mb_at_end` (just before workspace cleanup),
  `free_disk_mb_post_cleanup`, `workdir_peak_bytes`, and `min_free_disk_mb`
  (the configured floor). Useful for spotting jobs trending near the
  precheck threshold without a SQL join.
- `insufficient_disk_space` — emitted instead of `job_accepted` when the
  precheck (`RUNNER_MIN_FREE_DISK_MB`, default 128) rejects a job. Carries
  `free_mb` and `required_mb`.

Keys are kept consistent across events where possible:

- `timestamp`
- `event`
- `submission_id`
- `job_id`
- `assignment_id`
- `course_id`
- `user_id`
- `runner_id`
- `test_id`
- `status`
- `queue_wait_ms`
- `execution_ms`
- `total_processing_ms`
- `tests_passed`
- `tests_failed`
- `tests_errored`
- `tests_timed_out`
- `skipped_count`
- `runner_active_jobs`
- `max_jobs`
- `available_capacity`
- `error_type`
- `error_message_summary`
- `failure_stage`
- `retryable`
- `attempt`
- `max_attempts`
- `retry_in_seconds`

Sensitive material is intentionally excluded: no shared secrets, no submission
contents, and no raw notebook payloads.

## Internal Metrics Endpoint

Authenticated admins can query:

- `GET /admin/metrics`

The response is JSON and includes:

- current `queueDepth`
- current `inFlightJobs`
- `activeRunners` seen recently
- per-runner active job and capacity values
- recent job counts grouped by final status
- average, p50, and p95 queue wait and execution times for the recent window
- compatibility counters since server start:
  - `compatibleAssignmentAttempts`
  - `incompatibleAssignmentAttempts`
  - `jobsBlockedNoCompatibleRunner`

This route is protected by the existing admin session auth. It is not exposed as
a public dashboard route.

## Configuration

Environment flags:

- `ENABLE_DIAGNOSTICS_COLLECTION`
  - default: enabled
- `VERBOSE_REQUEST_TIMING`
  - default: disabled
  - when enabled, request timing logs are emitted more broadly instead of only
    for the key backend paths we always track
- `JOB_METRIC_RETENTION_DAYS`
  - default: `30`
- `RUNNER_SNAPSHOT_RETENTION_DAYS`
  - default: `14`
- `AUDIT_LOG_RETENTION_DAYS`
  - default: `90`; `0` disables the audit-log reaper
- `SUBMISSION_RETENTION_DAYS`
  - default: `365`
  - how long after a course is archived ("end of term") its student
    submissions become eligible for purging on the admin **Retention** tab
    (`/admin/retention`). Report-first: an admin triggers the purge manually;
    this only controls when a course is flagged as eligible. See FIPPA /
    UWaterloo TL55.
- `RUNNER_ACTIVE_WINDOW_SECONDS`
  - default: `120`
- `METRICS_RECENT_WINDOW_HOURS`
  - default: `24`
- `OBSERVABILITY_PRUNE_INTERVAL_HOURS`
  - default: `24`
- `RUNNER_NETWORK_RETRY_ENABLED`
  - default: enabled
- `RUNNER_DOWNLOAD_RETRY_MAX_ATTEMPTS`
  - default: `6`
- `RUNNER_RESULT_UPLOAD_RETRY_MAX_ATTEMPTS`
  - default: `8`
- `RUNNER_HEARTBEAT_RETRY_MAX_ATTEMPTS`
  - default: `4`
- `RUNNER_RETRY_BASE_DELAY_MS`
  - default: `1000`
- `RUNNER_RETRY_MAX_DELAY_MS`
  - default: `30000`

Pruning runs opportunistically on server startup and then whenever the service
next needs to prune after the configured interval.

Runner retry behavior is intentionally stage-specific:

- polling keeps retrying indefinitely through short server restarts
- heartbeats retry within a bounded window and then resume on the next interval
- submission and test-setup downloads retry before the active job is failed
- result uploads retry longer than heartbeats so transient API restarts are less
  likely to lose a completed grade

## Deployment Examples

Docker Compose:

```bash
docker compose logs -f server | jq -R 'fromjson?'
curl -b admin-cookie.txt http://localhost:8080/admin/metrics | jq
```

systemd / journalctl:

```bash
sudo journalctl -u chickadee-server -f
sudo journalctl -u chickadee-runner -f
curl -H "Cookie: $(cat admin-cookie.txt)" http://127.0.0.1:8080/admin/metrics | jq
```

Connection recovery signals:

- `event == "server_connection_lost"` marks the first observed runner-side
  outage for a given interruption
- `event == "network_retry_scheduled"` and `event == "heartbeat_retry_scheduled"`
  show bounded retry decisions, including `failure_stage`, `attempt`, and
  `retry_in_seconds`
- `event == "server_connection_restored"` marks the first successful runner
  request after the outage clears

## Answering Common Ops Questions

Can I add more runners?

- Check `/admin/metrics` for sustained non-zero `queueDepth`, rising queue wait,
  and runners with `availableCapacity` near zero.

Are jobs timing out more than usual?

- Look at `jobStatusCounts.timeout` in `/admin/metrics`, then confirm in logs
  with `event == "job_finalised"` or runner `event == "timeout"`.

Which runner is overloaded?

- Compare `runnerLoads[].activeJobs`, `availableCapacity`, and recent runner
  heartbeat/poll events for the same `runner_id`.

Are failures mostly test failures or infrastructure errors?

- Use `job_execution_metrics.final_status` for the high-level split, then use
  `assignment_result_summary`, `test_result_summary`, and runner
  `local_execution_error` logs to separate test failures from infrastructure or
  execution issues.

## Memory / process measurement limitations

Peak memory and child-process counts are collected centrally in the native
runner subprocess wrapper.

On Linux, the runner samples `/proc` for the worker-created process group and
sums RSS across that group. This is a practical approximation for peak memory
usage and descendant count, but it is not a kernel-level cgroup peak:

- very short-lived grandchildren may be missed between samples
- non-Linux platforms currently leave these fields null

The abstraction is intentionally generic so container-specific metrics can be
added later without changing the stored schema.

## User-row foreign-key cascade

Every column that references `api_users.id` and the policy that fires when
the user row is hard-deleted via `POST /admin/users/:userID/delete`.

| Table | Column | On delete | Notes |
|---|---|---|---|
| `submissions` | `user_id` | SET NULL | Submission row preserved as immutable grade history; "anonymous attempt." |
| `submissions` | `retested_by_user_id` | SET NULL | Submission row preserved; retest attribution drops. **Enforced by `AddUserFKConstraints` on Postgres; by `AdminRoutes.deleteUser` on SQLite.** |
| `course_enrollments` | `user_id` | CASCADE | Enrollment row goes when the user goes. |
| `class_achievements` | `user_id` | CASCADE | Derived per-user row; goes with the user. **Enforced by `AddUserFKConstraints` on Postgres; by `AdminRoutes.deleteUser` on SQLite.** |
| `client_diagnostics` | `user_id` | CASCADE | Browser-error breadcrumb; tied to the user. |
| `assignment_personalization_seeds` | `user_id` | CASCADE | Per-user seed; gone with the user. |
| `job_execution_metrics` | `user_id` | SET NULL | Metric row preserved for capacity reporting; user attribution drops. |
| `audit_log` | `actor_user_id` | SET NULL | Audit row preserved; actor link drops. |
| `audit_log` | `actor_username` (denormalised string, no FK) | **preserved verbatim** | Audit log is a forensic record. "Who did what" must survive even when the user row is gone — otherwise incident-response queries blank out. The denormalised column is the only attribution that remains after the FK breaks. |
| `pre_enrollments` | `username` (string) | **N/A** | Not an FK to `api_users` — pre-enrollment rows pre-date the user row and resolve by username on first login. |

### Implementation note

Of the FK constraints above, two (`submissions.retested_by_user_id` and
`class_achievements.user_id`) were created as bare UUID columns and lack
a DB-level constraint on existing deployments. The `AddUserFKConstraints`
migration adds them on Postgres. SQLite cannot add an FK to an existing
column without recreating the table, so on SQLite the same semantics are
enforced by application code in `AdminRoutes.deleteUser` — it explicitly
clears `class_achievements` rows and nulls `retested_by_user_id`
references before deleting the user row. Both backends end up with the
same observable behaviour.
