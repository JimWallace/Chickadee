### Fixed

- **The submission result band lays out correctly on every attempt after the
  first.** The grade, the points, the delta remark and the four count tiles were
  peers in one flex row, so a delta line — which appears on every attempt but
  the first — pushed the tiles into a 3+1 wrap and left a gap beside the grade.
  The band is now the two groups the design describes: a stacked grade block and
  a tile row, with the delta on its own full-width line beneath. The fixture
  grades twice so a baseline covers the case at all, which also gave the results
  table's Δ column its first coverage — and caught an empty `<th>` in the
  hidden-test table that axe flags as `empty-table-header`.
