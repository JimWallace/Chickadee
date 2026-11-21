### Changed

- **The browser grading cells are part of the student contract.** The four
  grading cells (`Public/python-grading-shared.js`,
  `Public/r-grading-shared.js`, `Public/lua-grading-shared.js` and
  `Public/octave-grading-shared.js`), the shared exit-code mapping
  (`Public/grading-shared.js`) and the kernel boot
  (`Public/xeus-kernel-shared.js`) decide how a browser-graded test is run and
  scored, so a change to them now ships only in a minor
  (`scripts/contract-paths.txt`, `docs/release-gate.md`).
