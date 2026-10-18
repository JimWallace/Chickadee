### Changed

- **Pushes to `main` no longer queue behind each other in CI.** The `swift-tests.yml` concurrency group for a push is now the commit SHA, not the shared `main` ref. Before, each newer push cancelled the waiting run (43 % of `main` runs were cancelled before any job started) and the rest waited a median 408 s for the run ahead of them. Pull request runs still cancel their superseded runs.
