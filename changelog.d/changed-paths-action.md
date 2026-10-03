### Changed

- **One change detector for the three CI jobs that skip when nothing they test changed.** `editor-smoke`, `codeql-js` and `browser-grading-smoke` each carried a copy of the same bash block, and the third had drifted: it did not fetch the base branch, and it skipped the browser grading smoke on an empty diff instead of running it. All three now use `.github/actions/changed-paths`, which takes a pattern and an optional exclude pattern and answers `relevant=true` for a non-PR event, a missing base commit or an empty diff. A change to the action runs all three jobs. Closes #1979.
