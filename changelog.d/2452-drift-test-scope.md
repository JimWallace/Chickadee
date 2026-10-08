### Fixed

- **The isolated-worker drift test now reads `grading-executors.js`.** #1965 moved the grading worker factory into that file, which the isolated notebook page loads, but the test still scanned only `browser-runner.js` and `notebook.js`. A literal worker spawn added there would have been refused by an isolated engine with no test failing. Two comments that still named `browser-runner.js` are corrected. (#2452)
