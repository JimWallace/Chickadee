### Fixed

- **A lock error no longer loses a badge, leaderboard entry or coverage row.** Five "first insert wins" saves used `try?`, which also hid the stale-snapshot lock error that the retry around the result side effects exists for. The rows were then lost with no log. A new `createIgnoringConflict` ignores only a constraint failure, so the retry now sees the lock error and runs again. (#2300)
