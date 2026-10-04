### Changed

- **Auto-compute has its own module.** The code that runs the solution for a pattern-family case, and writes the answer into the Expected cell, moved from `pattern-family-editor.js` into `Public/auto-compute-client.js`. The editor keeps only the decision of when a row is computed. A unit test with a fake worker now covers the routing, the time limits and the kill on timeout (#1966).
