### Added

- **Assignments can be upload-only (`submissionMode: "upload"`).** A new
  manifest field beside `gradingMode` declares how students hand work in:
  `notebook` (the JupyterLite workflow, the default and the behaviour of
  every existing assignment) or `upload`, which removes the editor surface
  entirely — the dashboard drops the Edit action, the notebook URL (including
  the assignment's vanity link) sends students to the upload form, and
  grading always runs on the native worker. This makes the shell-script +
  makefile path a first-class product surface for work the notebook workflow
  cannot carry: makefile-graded compiled languages such as C++, and
  multi-file projects submitted as a zip. The upload form now lists the
  assignment's `requiredFiles` and derives its file-picker hint from the
  language table plus those files (the hand-listed hint had gone stale twice
  — it never learned `.lua` or `.m`). The incoherent `upload` + `browser`
  combination is refused on every authoring surface (edit page, MCP
  `set_grading_mode`, the test-setup upload API), section moves skip adopting
  a browser default for upload assignments, and `effectiveGradingMode` pins
  imported bundles that carry the pair to worker grading anyway. Suite
  rebuilds now also preserve `requiredFiles`, which a rebuild previously
  reset to empty.
