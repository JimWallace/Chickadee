### Changed

- **The Python browser grading cell and the shared grading code are part of
  the student contract.** `Public/grading-shared.js`,
  `Public/python-grading-shared.js` and `Public/xeus-kernel-shared.js` decide
  how a browser-graded test is run and scored, so a change to them now ships
  only in a minor
  (`scripts/contract-paths.txt`, `docs/release-gate.md`).
