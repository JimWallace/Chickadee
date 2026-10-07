### Changed

- **The browser grading router derives its interpreter table.** Which browser substrate a test's interpreter routes to was a hand-written table, so a new kernel language could get a grading worker and still route to "unsupported". `scripts/generate-js-constants.sh` now writes the table from each kernel language's generated test extension and the interpreter RunnerCore classifies it as, and fails when a kernel language has no such interpreter. (#2388)
