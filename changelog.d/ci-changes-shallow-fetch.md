### Fixed

- **CI: the Swift scope check fetches only what it compares.** The `changes` job in `swift-tests.yml` checked out the full history of every branch and tag, and since 2026-11-03 17:30 UTC that fetch has run into the job's 5-minute limit on every run. The gate fails closed, so every pull request was red. A pull request now fetches depth 2, the merge commit and both parents. A push fetches its before commit by itself. Any failure still runs the full suite.
