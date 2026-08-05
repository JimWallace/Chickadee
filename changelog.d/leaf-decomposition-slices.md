### Fixed

- **Per-student `=` expressions no longer degrade to literal strings on the
  Create Assignment page.** That page carried a pre-v0.4.160 inline copy of the
  section-inputs editor whose value parser had no `=` branch, so an expression
  typed into a section input was persisted as the literal text and the payload
  omitted `expressions` entirely. It now loads the same shared modules the edit
  page uses.
- **Section drag-reorder now persists on the Create Assignment page.** The
  reorder endpoint was derived from the suite URL by rewriting a trailing path
  segment, which no-ops on that page's query-string URL and posted to a GET/PUT
  endpoint; the page's own fallback handler read an out-of-scope `draftID` and
  threw before its request. The list reordered on screen, nothing was saved, and
  a failure alert appeared. The endpoint is now an explicit, required builder.
- **Deleting a suite section no longer raises two confirmation dialogs** on the
  Create Assignment page, which bound duplicates of handlers `suite-table.js`
  already owns.

### Changed

- **The suite-section shells are one shared partial** (`_suite-sections.leaf`),
  used by both authoring surfaces, parameterized on the per-page endpoint base
  and whether its forms submit in place.
- **`checkUWDates` is shared** (`ChickadeeUI.checkUWDates`) instead of living as
  three inline copies that had drifted on null-handling and on label text. Both
  labels are preserved.
