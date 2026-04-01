# Operational Diagnostics

Chickadee now records backend-only operational diagnostics for submission jobs,
runner execution, and server request timing. This data is intended for later
analysis; there are no dashboards or UI surfaces in this change.

## What Is Collected

### Submission / job diagnostics

Stored in `submission_diagnostics`, keyed by `submission_id`.

Captured fields include:

- `submitted_at`
- `assigned_at`
- `started_at`
- `finished_at`
- `queue_wait_ms`
- `execution_ms`
- `turnaround_ms`
- `final_status`
- `runner_id`
- `timed_out`
- `exit_code`
- `termination_reason`
- `peak_rss_bytes`
- `wall_clock_ms`
- `child_process_count`
- `stdout_bytes`
- `stderr_bytes`

Definitions:

- `queue_wait_ms = started_at - submitted_at`
- `execution_ms = finished_at - started_at`
- `turnaround_ms = finished_at - submitted_at`

When a timestamp or metric is unavailable, the corresponding column is left
null. Diagnostics collection is best-effort and must not block job execution.

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

Machine-readable structured log events are emitted for:

- `job_submitted`
- `job_assigned`
- `job_started`
- `job_finished`
- `job_failed`
- `job_timed_out`
- `runner_available`
- `request_completed`

Field names are kept consistent across events where possible:

- `submission_id`
- `runner_id`
- `course_id`
- `assignment_id`
- `test_setup_id`
- duration fields such as `queue_wait_ms`, `execution_ms`, `turnaround_ms`

## Configuration

Environment flags:

- `ENABLE_DIAGNOSTICS_COLLECTION`
  - default: enabled
- `VERBOSE_REQUEST_TIMING`
  - default: disabled
  - when enabled, request timing logs are emitted more broadly instead of only
    for the key backend paths we always track

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
