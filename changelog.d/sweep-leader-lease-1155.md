### Fixed

- **Periodic sweeps now run on exactly one server process (#1155).** Every
  sweep — session/activity/audit/OAuth reapers, stuck-submission reaper,
  deadline sweep, achievement sweep, health alerts, BrightSpace grade sync,
  LEARN roster/section syncs — previously started on every instance, so a
  multi-process deployment pushed grades to LEARN from N processes at once
  and fired duplicate health alerts. Each `PeriodicSweepMonitor` tick now
  claims/renews a per-sweep leader lease (`sweep_leases` table, atomic
  conditional UPDATE) and only the holder runs the sweep body; a crashed
  leader's sweeps fail over to another instance within roughly one missed
  cycle (TTL = 2× interval, min 2 min). Single-process deployments always
  hold the lease at the cost of one small query pair per tick.
