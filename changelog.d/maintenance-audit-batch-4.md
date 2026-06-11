### Changed

- **Maintenance audit batch 4 (efficiency + drift fixes).** Hot-path query
  cleanups: vanity-URL assignment resolution filters by slug in SQL instead of
  fetching every assignment in the course; `nextAssignmentSortOrder` no longer
  loads every assignment to compute a max; admin course-copy probes all
  candidate `-COPY-n` codes in one query (was up to 10 round-trips, now
  pinned by a route test); the admin overview reuses one date formatter
  across course rows. Case-insensitive active-course-by-code resolution is
  consolidated into a shared `findActiveCourse(byCode:)` (was duplicated in
  the vanity-URL and student-history routes). The web "move to section"
  grading-mode sync now calls the same `setManifestGradingMode` helper as the
  MCP tool, so both paths emit identical sorted-key manifest bytes — the
  manifest-hash retest gate depends on that determinism. Worker workspace
  cleanup failures now emit a structured `workspace_cleanup_failed` log event
  instead of vanishing (silent disk leaks). The duplicated git-restore-mtime
  CI steps moved into one composite action.
