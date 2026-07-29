### Added

- **Design review of the language-dispatch surface.** `docs/language-handling-review.md`
  answers the review brief from PR #1234: hoist R notebook extraction into
  RunnerCore before WebR (#77), consolidate the duplicated script-extension
  sniff, shrink the `AssignmentLanguage.resolve` public surface, and adopt a
  drift-guard hierarchy plus a same-PR adoption rule. Also corrects the stale
  `CLAUDE.md` claim that the R pattern-family / notebook-check renderers are
  deferred (they shipped in #1207).
