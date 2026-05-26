### Changed

- **Instructor view split into tabs.** The instructor dashboard now uses the
  same tabbed layout as the admin view. **Overview** keeps the dashboard
  metrics and the assignment/section listing; **Students** moves the enrolled-
  students roster to its own panel that self-updates every few seconds (like
  the admin Users panel) via a new `GET /instructor/students-data` poll
  endpoint; and a new **BrightSpace** tab hosts the "Export Grades CSV" button
  (moved off the Overview header) alongside the automatic grade-sync status.
