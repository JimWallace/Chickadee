### Changed

- **The notebook page keeps its pure rules in a core file.** The new
  `Public/notebook-core.js` holds the editor readiness probes, the kernel
  recovery and reseed decisions, and the results formatting. The page loads
  it before `notebook.js`. Three node test suites now load the core
  directly. They no longer boot all of `notebook.js` under a stub DOM.
  (#1967)
