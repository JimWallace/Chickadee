### Changed

- **The assignment-editor surface stopped writing its own styling from JS.**
  The pattern-family editor, suite table, inputs editors, Test Editor modal
  and both test renderers now assign classes from a shared editor-table
  vocabulary in `styles.css` (`.cell-*`, `.th-*`, `.modal-*`, `.editor-stack`)
  instead of carrying style strings, taking the `JS_STYLE_DECISION_BASELINE`
  ratchet from 118 to its floor of 14 (the sanctioned popover-geometry and
  custom-property writes). Validity cues — invalid names, per-student `=`
  tints, `$name` resolution, auto-computed values — are toggled classes with
  palette colours, so they now adapt to dark mode; the previous
  `rgba(45,143,71,.07)` expression tint and the off-scale `.7rem`/`.78rem`
  font sizes are gone. JS-added inputs rows and their server-rendered twins
  share one set of classes, removing a live drift (the two ran different
  font sizes in the same table); the global-inputs rows join the same
  dense-table size as every other editor table.

- **The editors' behaviour-only class hooks took the `js-` prefix.** All
  pattern-family, suite-table, inputs-editor, section-CRUD and
  achievements-editor hooks were renamed (`pf-case-remove` →
  `js-pf-case-remove`, etc.), and two dead hooks were deleted outright,
  shrinking the class-resolution allowlist from 67 entries to 18. The suite
  table's focus restore now keys on the `js-` hook rather than the first
  styling class it happens to find.
