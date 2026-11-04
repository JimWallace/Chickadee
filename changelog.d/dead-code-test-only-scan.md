### Fixed

- **The dead-code scan builds again.** `dead-code.yml` moved the index store with `-index-store-path`, and SwiftPM test discovery on Linux could not find it, so every run failed at the build. The job now keeps the index at SwiftPM's default path and scans it there.

### Changed

- **The dead-code scan also lists code that only tests use.** `dead-code.yml` now adds `results-without-tests.json`, a scan with the test targets left out, to its report. `docs/dead-code-scan.md` explains how to read it.
