### Changed

- **Dependabot watches npm and pip.** It covered `swift`, `docker` and
  `github-actions` only, so ESLint, Playwright, esbuild, the CodeMirror
  vendoring inputs and the JupyterLite build pins were never tracked. Swift and
  Actions updates are now grouped to keep a quiet period from producing one PR
  per transitive pin; SwiftLint is deliberately excluded from that grouping,
  because `swiftlint.sh --strict` turns a new rule in a patch release into a
  red `format-lint`.
