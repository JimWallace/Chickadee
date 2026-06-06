### Changed

- **Removed the separate "Validate & open" page.** Validation is tied to saving
  an assignment (creating or editing it auto-runs validation), so the
  `/instructor/:id/validate` page and every link to it are gone. The legacy
  "Publish…" action now opens the editor to finalize the draft. On the
  instructor dashboard, a staff-only (preview) assignment now shows the normal
  published-assignment actions (copy link / edit / retest / delete) instead of a
  stray "Validate & open" button, and on the main page it shows a single
  "staff only" pill rather than both "open" and "staff only".
