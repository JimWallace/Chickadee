### Fixed

- **The editor smoke and the notebook probes run when the files they load change.** The editor-smoke change detector did not match `grading-executors.js`, `runner-support-sources.js` or `_notebook-body.leaf`, and the four notebook probes did not list the two templates that build the page they load. (#2427)
