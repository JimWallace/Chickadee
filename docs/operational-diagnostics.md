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

Definitions:

- `queue_wait_ms = assigned_at - enqueued_at`
- `execution_ms = completed_at - started_at`
- `total_processing_ms = completed_at - enqueued_at`

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
- `RUNNER_ACTIVE_WINDOW_SECONDS`
  - default: `120`
- `METRICS_RECENT_WINDOW_HOURS`
  - default: `24`
- `OBSERVABILITY_PRUNE_INTERVAL_HOURS`
  - default: `24`

Pruning runs opportunistically on server startup and then whenever the service
next needs to prune after the configured interval.

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
