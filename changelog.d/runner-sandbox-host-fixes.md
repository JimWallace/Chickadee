### Fixed

- **The deployer reports a runner that does not stay up.** After a release, the deployer recreates the Compose runner. Before, it recorded `runner-refresh ok` as soon as `docker compose up` returned, also when the runner then exited at startup and Docker restarted it in a loop: for example, `--sandbox` on a host that refuses user namespaces. It now waits 15 seconds, asks Docker whether the runner is still running without a restart, and records `runner-refresh failed` with the runner's last error line when it is not. The deploy itself is not rolled back.

### Changed

- **`deploy/README.md` gives the Ubuntu fix for the runner sandbox.** It shows how to read and change `kernel.apparmor_restrict_unprivileged_userns`, what the change costs, why the runner must be recreated with `--force-recreate` after a host change, and that an override file's runner `command:` needs `--sandbox` too.
