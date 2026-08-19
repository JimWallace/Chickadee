### Fixed

- **The browser-graded results view matches the server-rendered one again.**
  `docs/ui-design.md` records the result-row classes as shared between
  `submission.leaf` and the browser runner's inline results, which means CSS
  changes reach both for free and markup changes do not. The score band and its
  outcome tiles are now built in `notebook.js` too, and its output disclosure
  carries the shared `.test-output-details` / `.test-output-pre` classes it had
  been missing, so the stylesheet's rules reach it.
