### Changed

- **A worker heartbeat test now waits for the daemon with a limit (#1949).**
  `workerDaemonHeartbeatFailuresDoNotStopPolling` cancelled the daemon and
  then waited for it with no limit. It now calls `awaitCancelledDaemon`, which
  waits 30 seconds at most and records an issue when the daemon does not stop.
