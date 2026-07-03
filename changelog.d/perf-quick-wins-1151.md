### Changed

- **Perf quick wins from the 2026-07 server audit (#1151).** The submission
  status endpoint (the 2 s student poll) grants owners access without the
  course-staff lookup, saving two DB queries per poll; the stuck-submission
  reaper flips aged-out jobs back to pending in one bulk `UPDATE` instead of a
  save per row; the retention report counts submissions with a grouped
  `COUNT(*)` instead of materializing every row; and
  `GET /api/v1/submissions/:id/results` now emits an `ETag` (keyed on result +
  visible tiers) and answers matching `If-None-Match` with 304 so repeat views
  skip the collection decode.

### Fixed

- **`RequestTimingMiddleware` is now actually registered.** It shipped in
  v0.4.573 but was never added to the middleware chain, so the
  `request_metrics` table behind the admin dashboard and the
  `get_request_metrics` diagnostic tool had been silently empty. Idle runner
  check-ins (204 polls, healthy heartbeats) are excluded from persistence so
  the hot worker-poll path doesn't gain a per-poll INSERT.
