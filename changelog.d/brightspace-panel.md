### Added

- **BrightSpace tab build-out (grade-sync console).** The instructor BrightSpace
  tab is now a working console for the D2L grade sync: a connection test
  (`whoami`), an assignment→grade-item mapping table with a dropdown sourced
  from the course's D2L grade book (free-text fallback), a sync-activity log,
  summary counts (synced / pending / errored / unmapped), an "unmapped students"
  diagnostic, and manual **Sync now** / **Retry failed** / per-assignment
  **Push all** actions. Grade pushes now write an append-only
  `brightspace_sync_log` audit trail (success / error / skipped-no-account).
  Course→org-unit binding stays an admin action and is now **verified against
  D2L on save** — the org-unit name is looked up and cached so the binding is
  confirmable at a glance. New D2L client calls: `whoami`, `getOrgUnit`,
  `listGradeObjects`. See [docs/architecture.md](../docs/architecture.md)
  → "BrightSpace grade sync".
