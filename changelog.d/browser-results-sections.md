### Changed

- **Browser-graded results are grouped by section.** The in-browser results
  shown after a student submits a notebook (`notebook.js`) and after an
  instructor validates a solution (`assignment-validate.js`) now render one
  table per test-suite section with an `<h3>` heading, matching the
  server-rendered submission view. The browser runner stamps each outcome with
  its manifest entry's `sectionID` (index correlation, mirroring the server's
  `groupOutcomesBySection`) and exposes a shared `BrowserRunner.groupBySection`
  helper; outcomes with no/unknown section fall into a trailing "Ungrouped"
  block, and assignments without sections render as a single flat table exactly
  as before. The `.submission-section-block` / `.submission-section-heading`
  styles moved into the global stylesheet so all three views share them.
