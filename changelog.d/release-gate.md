### Added

- **The release gate (docs/release-gate.md).** Production now deploys by a
  mode that an admin sets on the new Deployment tab of the admin panel:
  autonomous, gated minors (the default) or manual, with pause beside it. In
  the default mode a patch deploys on its own and a minor waits until an admin
  approves it by typing its version; a major always waits. The tab shows what
  runs, the held release with its release notes (contract changes flagged),
  and the deploy history. The page only sends requests through a new
  read-write `requests/` mount, and the deploy daemon accepts only
  approve-the-held-release, mode, pause and resume, each recorded with the
  admin's name. Rollback stays a host action. `get_deploy_status` reports the
  mode and the held release.
- **Contract changes ship only in a minor.** `scripts/contract-paths.txt`
  lists the student contract (the vendored kernels and editor, the runner
  wasm, the kernel pins, `Sources/RunnerCore/`). The new `contract-change`
  check fails a pull request that changes one without the `minor-release`
  label, auto-release cuts no release while such a change is on `main` and
  opens a `minor-needed` issue instead, and kernel re-vendor and JupyterLab
  dependency pull requests are labelled `minor-release` and no longer
  auto-merge.

### Changed

- **The deployer remembers pause and approval across a restart,** including
  the restart after it updates its own scripts, so an approved release is no
  longer held again. `CHICKADEE_DEPLOY_GATE_LEVEL` is no longer read; the mode
  file replaces it.
