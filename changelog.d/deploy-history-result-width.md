### Fixed

- **The Deployment history's Result pill stays in its column.** At desktop
  width the Result column was 5rem, so the "rolledback" pill ran about 7px past
  its cell and "recovered" about 5px. The column is now 6.5rem wide on this
  list only. The visual-regression fixture now has a "rolledback" and a
  "recovered" row, and the cell-overrun check measures a pill by its box, not
  only by its text.
