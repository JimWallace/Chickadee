### Added

- **BrightSpace grade sync auto-retries transient failures.** A push that fails
  on a transient D2L/transport hiccup (HTTP 408/425/429/5xx or a network error)
  now stays queued and is re-attempted on the next sweep automatically; only
  terminal failures (a 4xx, a missing student account, no parseable grade) clear
  the flag and wait for a manual "Retry failed". Previously every failure waited
  for a manual retry.
- **Health alert when grade sync starts failing.** A new `brightspaceSyncFailing`
  alert fires when at least `ALERT_BRIGHTSPACE_SYNC_FAILURE_THRESHOLD` (default 3)
  grade pushes fail within `ALERT_BRIGHTSPACE_SYNC_FAILURE_WINDOW_MINUTES`
  (default 60), surfacing the latest D2L error — so an operator knows grades
  stopped flowing without watching the dashboard.

### Fixed

- **Pushed grades are rounded to 2 decimals** so a scaled value lands as `8.57`
  in the LEARN gradebook instead of `8.571428571…`.
