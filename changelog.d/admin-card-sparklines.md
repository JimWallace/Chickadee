### Added

- **Sparklines on the admin diagnostic cards.** Each of the five Overview
  cards (Max Queue, Jobs Processed, Max Load, P95 Wait, P95 Execution) now
  renders a mini bar chart of its trend, and clicking a card cycles its time
  window through 24h → 7d → 30d. Backed by a new
  `GET /admin/metrics/cards` endpoint that returns all three windows in one
  payload (per-bucket peak queue depth, completed jobs, peak runner
  utilization, and queue-wait/execution P95s), so cycling is instant and the
  dashboard polls once a minute instead of every 15 seconds.
