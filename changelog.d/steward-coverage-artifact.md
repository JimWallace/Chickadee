### Changed

- **The nightly coverage run keeps its per-file report.** `test-coverage.yml` uploads `coverage.lcov` as the `coverage-lcov` artifact for 8 days. Before, the run kept only the total, so the nightly steward could not find coverage gaps.
