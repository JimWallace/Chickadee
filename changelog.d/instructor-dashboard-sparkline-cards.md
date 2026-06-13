### Added

- **Instructor dashboard diagnostic cards now have sparklines + cyclable time
  windows.** The Submissions, Active Students, and Active Assignments cards on
  the instructor overview gained the same click-to-cycle 24h / 7d / 30d
  sparkline treatment as the admin dashboard, fed by a new course-scoped
  `GET /instructor/metrics/cards` endpoint. The whole series is derived from a
  single trailing fetch of the longest window's student submissions (projected
  to the three columns the buckets need), so the dashboard's poll stays cheap.
  The sparkline renderer and card styles are now shared between the admin and
  instructor dashboards (`ChickadeeUI.renderSparkline`, global card CSS). The
  Queued Right Now and Students With Browser Errors gauges remain static cards.
