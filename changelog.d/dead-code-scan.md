### Added

- **Weekly dead-code scan.** `.github/workflows/dead-code.yml` runs Periphery Pro on Linux every Sunday and uploads a `dead-code-report` artifact that lists unused Swift declarations. It is a report, not a gate. `.periphery.yml` holds the scan options, and `docs/dead-code-scan.md` explains how to read the report and how to update the tool.
