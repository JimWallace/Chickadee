### Added

- **ESLint gate for first-party frontend JS (#1134).** `eslint:recommended`
  (zero-warnings, `scripts/eslint.sh`) now covers `Public/*.js` and the
  frontend test suite, wired into the CI `browser-runner-tests` job. The
  initial pass fixed the real findings it surfaced: four same-scope `var`
  redeclarations in the suite editor's drag-and-drop code, five pieces of
  dead code left behind by earlier refactors, and a handful of unused
  parameters. Vendored trees (`Public/pyodide`, `Public/jupyterlite`,
  `Public/vendor`) are excluded; config and shared globals live in
  `eslint.config.mjs`.
