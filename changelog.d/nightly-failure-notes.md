### Added

- **Notes on a failed nightly clean build.** When `test-coverage.yml` fails, `nightly-failure-notes.yml` has a small model read the failed log and the commits since the last green nightly, and comment on the "Nightly clean build failing" issue: the failed step, the first error, and the commits that likely caused it. It changes and re-runs nothing.
