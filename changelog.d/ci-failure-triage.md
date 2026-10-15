### Added

- **Automatic CI failure triage.** When a CI workflow fails, `ci-triage.yml` has a small model read the failed log against `docs/ci-flakiness.md` and post one comment on the PR (or on the commit on `main`): a known flake family, a real failure with its first error, an infrastructure death, or "unclear". It never re-runs a job and never blocks a merge.
