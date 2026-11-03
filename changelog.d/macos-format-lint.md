### Fixed

- **The format-lint gate runs on macOS.** `check-styles.sh` expanded a possibly
  empty array under `set -u`, which macOS's bash 3.2 rejects, and
  `check-ui-vocabulary.sh` passed newline-separated lists to awk with `-v`,
  which BSD awk rejects. Both now use forms that GNU and BSD tools accept.
- **SwiftLint runs on a Mac whose `xcode-select` points at the Command Line
  Tools.** `scripts/swiftlint.sh` now uses Xcode's developer directory, where
  SourceKit lives, when Xcode is installed and `DEVELOPER_DIR` is unset.
