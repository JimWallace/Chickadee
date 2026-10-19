### Changed

- **Fewer CI runners per pull request (#2719).** The mutation, deployer and handle-review self-tests now run in one `script-self-tests` job, and the Claude Code hook tests run in `guard-self-tests`. The four Swift test lanes share `scripts/ci-swift-test-lane.sh` for the build-skip branch and the skipped-test check. The Muter cache keys use the hash of `scripts/mutation-run.sh`, which holds the pin, so the keys no longer copy it. The JupyterLite job uses a shallow checkout.

### Removed

- **`mutation-baseline-probe.yml`.** Its question has an answer: privileged WorkerTests pass 20 of 20 in the mutation baseline. `repeat-test.yml` runs a test selection N times if the need returns.
