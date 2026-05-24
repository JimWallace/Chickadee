### Changed

- **Versions are now assigned at merge time, not in PRs.** PRs add a fragment
  under `changelog.d/` instead of editing `VERSION`, `ChickadeeVersion`, or
  `CHANGELOG.md` — which removes the guaranteed text conflict that made
  concurrent PRs thrash. A new `auto-release` workflow folds the fragments into
  a versioned `CHANGELOG` section on merge to `main`, bumps the version, and
  tags the release (`scripts/assemble-release.sh`). CI workflows gained a
  `merge_group:` trigger so an optional GitHub merge queue can re-test PRs
  against the real pre-merge `main`. See `docs/release-process.md`.
