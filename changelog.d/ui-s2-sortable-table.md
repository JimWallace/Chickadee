### Changed

- **One sortable table (audit S2).** Every sortable column on every page now
  runs the shared `Public/sortable-table.js`, replacing five page-local sort
  implementations across three different header dialects. Sorting is
  keyboard-accessible everywhere (the header is a real button) and announces
  itself to screen readers via `aria-sort`; a column's load-time sort is
  declared in markup rather than scripted per page; and a table whose rows
  are repainted by a background poll now keeps the sort the user chose.
