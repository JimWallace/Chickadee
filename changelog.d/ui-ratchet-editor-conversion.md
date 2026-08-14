### Changed

- **The assignment editors no longer write styling from JavaScript.** The
  pattern-family, suite-table, test-editor, and inputs editors built their
  rows and modals with inline style strings and per-property colour writes,
  which bypassed the palette and type scales and left their validity cues
  without dark-mode values. All of it now rides shared stylesheet classes
  (the `.cell-input` family, the `.modal-*` shell, the `.input-*`
  value-state cues), and JS-added input rows carry the same classes as
  server-rendered ones, removing two small rendering drifts between the two.
  The JS styling-decision ratchet drops 118 → 10, and two idioms that
  reached zero are now absolute CI rules: no colour or typography property
  written via `.style`, and no `style=""` in a JS-built HTML string beyond a
  custom property. The editors' behaviour-only class hooks also adopted the
  `js-` prefix, shrinking the class-resolution allowlist 67 → 22.
