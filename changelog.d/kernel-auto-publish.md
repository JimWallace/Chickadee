### Changed

- **Kernel updates publish themselves.** When the weekly kernel currency check
  finds the vendored xeus kernels behind their channels, it now dispatches
  `revendor-kernels.yml` in a new publish mode. That rebuilds from `main`,
  verifies, and opens the update as a pull request with auto-merge on, so the
  browser grading and editor smoke test the new kernels before they reach
  `main`. It does nothing while a re-vendor pull request is already open.
- **The re-vendor workflow pushes with `RELEASE_TOKEN`.** The branch ruleset
  refused its `GITHUB_TOKEN` push (GH013, required `editor-smoke-gate`), so a
  manual re-vendor could rebuild and verify but never commit.
