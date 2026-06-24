### Changed

- **Trimmed each dashboard to four diagnostic cards.** The instructor overview
  (`/instructor`) drops its "Queued Right Now" gauge, the admin dashboard
  (`/admin`) drops "P95 Execution Time", and the per-assignment submissions page
  (`/instructor/:id/submissions`) drops "Queued Jobs". Fewer cards reduce
  on-screen clutter and reflow more cleanly on mobile. The admin
  `/admin/metrics/cards` endpoint still computes `executionP95Ms` for the
  diagnostic API; only the card was removed.
