### Changed

- **Runner-offline alert no longer depends on the queue.** The runner-offline
  health rule now fires whenever a runner we've seen this session stops checking
  in for `ALERT_RUNNER_OFFLINE_SECONDS` (default 300s), regardless of whether
  any submissions are pending. It still stays quiet on a runner-less deployment
  and auto-resolves once a long-dead runner ages out of the dashboard window.
  This collapses the previous two-mode (urgent-while-queued vs. proactive-while-
  empty) design and removes the now-unused `ALERT_RUNNER_ABSENT_SECONDS` setting.
  The admin Health Alerts page reflects the new threshold wording.
