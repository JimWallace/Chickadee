### Performance

- **Column sorting reads each row once per sort instead of once per
  comparison.** `sortable-table.js` called `cellValue()` from inside its
  comparator, so sorting 1,000 rows did 17,050 cell reads and the same number of
  `querySelector` calls — 17× what a decorated sort needs — and 109,452 (21.9×)
  at 5,000 rows. It is now 1 read per row (2 where the table declares a
  tiebreak column), and the reorder moves rows in a single `DocumentFragment`
  insertion rather than one `appendChild` per row. This is not a click-time
  cost: `data-sort-initial` seeds the sort at load, so `table-poll.js` re-ran it
  on every 5-second repaint of the roster and users tables.

### Changed

- **`sortable-table.js` and `list-filter.js` state where their cell rules
  diverge.** The sorter's comment claimed the filter shared its cell-value rule
  while the filter implemented one of its four cases. They differ on purpose —
  you sort Last Seen by its ISO timestamp and filter it by the "2 hours ago" a
  reader can see — and both files now say so. Only the `<select>` case is
  common to both.

### Fixed

- **The sort's DOM surgery is now tested.** `sortable-table.test.mjs` covered
  the pure ordering rules only, which is how the comparator-side reads survived
  the S2 consolidation; it now also pins the row order, the tiebreak, the
  one-read-per-row budget, the single tbody mutation, and re-reading after a
  repaint.
