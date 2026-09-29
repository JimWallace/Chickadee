### Added

- **Sandbox startup probe.** With `--sandbox`, the runner now checks that the host can start the sandbox before it polls for jobs. If it cannot, the runner exits and says why. Before, a container that refuses user namespaces made every job fail.
