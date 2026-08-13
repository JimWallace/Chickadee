### Changed

- **The student dashboard no longer loads the full submission history to render.**
  The per-setup grade/submission maps are now computed by the database — a
  window-function pick for the latest submission + attempt count, and a
  `MAX` over the same grade fraction `gradePercentValue` reads for the best
  grade — instead of materializing every submission and every result the
  student ever made and folding them in Swift, two reads that grew all term
  (#1382 item 2). Badge evaluation now fetches results only for the latest
  and prior attempt per assignment, and the achievements helper reuses the
  setup rows the dashboard already loaded rather than re-selecting them,
  manifest blobs included.
