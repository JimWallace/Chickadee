### Added

- **Admin dashboard "Active Users" chart.** The admin overview now shows a
  full-width bar chart of distinct active users per time bucket over a
  selectable 24-hour / 1-week / 1-month window, beneath the existing
  diagnostics, runners, and courses sections. A new `user_activity_events`
  table records throttled per-user activity pings (written by
  `UserActivityMiddleware`, at most once per user per 5 minutes); the chart is
  served by `GET /admin/activity` and reaped to a 35-day retention by a new
  hourly sweep.
