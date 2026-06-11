### Changed

- **Maintainability batch from the June 2026 audit.** Seven periodic services
  now share one `PeriodicSweepMonitor` instead of hand-rolled monitor
  scaffolds; submission status and user role comparisons are typed enums;
  the notebook working-copy filesystem logic moved into its own service (and
  the pre-v0.4 legacy notebook sweep runs once at boot instead of on every
  page view); a shared `Public/chickadee-ui.js` replaces ten drifted
  `escapeHtml` copies and seven CSRF readers; the four multipart body structs
  collapse into one per route via a `MultipartFileList` decoder.
- The BrightSpace grade-sync sweep batch-loads its lookups and dedupes pushes
  per (student, assignment) instead of issuing ~5 queries per pending result.
- `GET /api/v1/submissions` supports `limit`/`offset` (default 500, max 5000,
  newest first) instead of returning the entire table.
