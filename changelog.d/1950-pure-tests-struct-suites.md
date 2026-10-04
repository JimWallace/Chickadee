### Changed

- **Seventeen pure-function tests no longer build a Vapor app (#1950).** They
  were in class suites that build an app in `init`, so each of them paid for
  an app that it did not use. They now sit in struct suites in the same
  files, with no `withApp` wrapper. No assertion changes.
