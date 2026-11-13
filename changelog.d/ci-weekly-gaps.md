### Added

- **Weekly macOS build.** `macos-build.yml` builds the package on macOS each
  Wednesday, with the Swift minor that `Package.swift` names, and runs the
  suites that need no Postgres and no interpreter, the macOS sandbox suite
  among them. Every other workflow runs on Linux. A red run files an issue
  labelled `scheduled-check-failed`, and the next green run closes it. No
  hosted runner has the macOS 27 SDK that the package floor needs yet, so the
  run fails at its first step until one does, and its issue records that macOS
  is not covered.
- **Visual regression runs weekly on `main`.** The pull request trigger is
  path-filtered, so a change outside its paths could alter a page unseen. The
  schedule compares `main` with the baselines that `main` carries, and a red
  run files an issue with a brief.

### Changed

- **Swift package currency reports to an issue.** A red `swift-currency.yml`
  run used to tell nobody. It now files one `dependency-update-failed` issue
  (key `swift-currency`) with the pins that are behind and a brief for an
  agent, and closes it when the pins are current again.
- **The weekly digest lists the weekly checks on `main`.** It reports the
  newest Swift currency, macOS build and scheduled visual regression runs, and
  asks a person when one is red, stale or missing.
