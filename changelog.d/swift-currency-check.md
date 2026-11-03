### Added

- **A weekly Swift package currency check.** Dependabot's Swift toolchain
  refuses the swift-tools-version 6.4 manifests, so no Swift update PR has
  opened since June. `.github/workflows/swift-currency.yml` runs
  `scripts/check-swift-currency.py` in the CI image every Monday: it resolves
  `/` and `/wasm` with `swift package update --dry-run` and goes red, naming
  each pin and its newer version, when one is behind. It is off the pull
  request path, so it never blocks a merge.
