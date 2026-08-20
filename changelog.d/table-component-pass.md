### Changed

- **The sort glyph marks the active column only.** Every sortable header
  carried a resting `↕`, so a six-column table drew six identical arrows and
  none of them said which column the rows were ordered by. Hover and keyboard
  focus now reveal it; the sorted column shows its direction permanently. The
  glyph hides with `visibility` rather than `content`, so revealing it cannot
  widen a column and reflow the table under the pointer.

### Fixed

- **A filtered table's bottom edge no longer shifts colour.** The rule
  suppressing the final row's separator targeted `:last-child` — the DOM's
  last row, not the last one a reader can see once `list-filter.js` hides rows
  with the `hidden` attribute. The stale separator collapsed with the table's
  own bottom border and won it (a cell beats the table in CSS conflict
  resolution), rendering that edge in `--gray-100` instead of `--gray-200`.
  `list-filter.js` now marks the last visible row and `sortable-table.js` asks
  it to re-mark after reordering.
