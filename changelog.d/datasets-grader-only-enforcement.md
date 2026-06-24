### Added

- **Datasets: grader-only file enforcement.** A file listed in
  `TestProperties.graderOnlyFiles` (option B — the reserved holdout / secret test
  set, see `docs/datasets.md`) is now withheld from every student-facing path —
  the JupyterLite editor symlinks, the student support-file download, the
  browser-runner zip download (served as a filtered copy), the browser manifest
  endpoint (the names), and the MCP support listing — while the native worker
  still receives it via the test-setup zip so grading scripts can read it. A
  strict no-op for assignments that declare none. Authoring (a UI/MCP way to
  designate a file grader-only, plus the worker-grading lock) follows.
