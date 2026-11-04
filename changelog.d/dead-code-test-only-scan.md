### Changed

- **The dead-code scan also lists code that only tests use.** `dead-code.yml` now adds `results-without-tests.json`, a scan with the test targets left out, to its report. `docs/dead-code-scan.md` explains how to read it.
