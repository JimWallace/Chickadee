### Fixed

- **`scripts/mutation-run.sh` runs under macOS bash 3.2.** It used `mapfile`, which needs bash 4, so a local shard run failed on macOS. Read loops now fill the two arrays. Empty lines are dropped, and an empty build-argument list no longer trips `set -u`.
