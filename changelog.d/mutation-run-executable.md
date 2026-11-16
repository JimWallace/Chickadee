### Changed

- **`scripts/mutation-run.sh` is executable.** It was the only script in `scripts/` without the executable bit, so a direct call failed with "permission denied". The workflows call it with `bash`, so they do not change.
