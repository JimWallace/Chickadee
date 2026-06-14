### Changed

- **Instructor dashboard: "Students With Browser Errors" is now a "Browser
  Errors" sparkline.** The static reconciled "students stuck right now" gauge is
  replaced by a cyclable 24h / 7d / 30d sparkline of raw browser-error events
  (`preflight_fail` + `watchdog_timeout` client diagnostics) per bucket, scoped
  to the course's enrolled students. Raw events (rather than the
  recovery-reconciled count) make a post-deploy decline visible, so instructors
  can confirm a browser-grading fix actually landed. Served by the existing
  course-scoped `GET /instructor/metrics/cards` endpoint. "Queued Right Now"
  remains the one static gauge.
