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
- **The student dashboard's filter and column sort were dead.** `index.leaf`
  declared `data-list-filter`, four sortable columns, `data-sort-initial`
  and a tiebreak — and loaded neither `list-filter.js` nor `sortable-table.js`
  (`base.leaf` loads neither; every other page includes them itself). The
  filter box accepted typing and filtered nothing, no result count was
  announced, the headers were inert, and assignments rendered in server order
  rather than by due date. It was invisible while the stylesheet drew a sort
  arrow on every column regardless. A new test pairs each declaration with the
  script that provides it.

### Changed

- **Phone tables get their gutter back.** At 640px and below the cell gutter
  drops one spacing step, so four columns no longer push the dashboard table
  past a 390px viewport. Row height is unchanged — that is what makes a row
  tappable.
