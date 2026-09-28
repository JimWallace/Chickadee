### Changed

- **The local-runner autostart launches through swift-subprocess.** It was the last Foundation `Process` in the repository, the launcher whose exit-detection socket leaks into concurrently started children. A new `SupervisedProcess` holds the runner, stops it with SIGTERM, then SIGINT, then SIGKILL, and appends its output to `results/local-runner.log` as before. `scripts/no-foundation-process.sh` now fails `format-lint` on any new Foundation `Process` launch.
