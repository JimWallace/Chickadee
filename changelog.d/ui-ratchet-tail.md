### Changed

- **The UI-maintainability ratchet closes out.** The last 21 removable
  entries leave the class-resolution allowlist: ten behaviour hooks that
  scripts genuinely read take the `js-` prefix (suite/family/check row
  actions, support-file delete, the publish due-date field, the notebook
  fallback notice, the submissions sparkline, the BrightSpace hidden-id
  field, the in-place error banner), and eleven class tokens that nothing
  read or styled — leftovers of earlier eras — are removed outright. The
  allowlist's one remaining entry, the sort component's `sortable-table`
  opt-in marker, is kept as a documented exception. The ratchet handoff
  document becomes the epic's closure record, with the standing rules for
  per-page revision work, and the visual-regression README documents how
  to run the harness in a remote container whose pre-installed browsers
  trail the lockfile.
