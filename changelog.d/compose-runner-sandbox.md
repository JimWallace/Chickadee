### Security

- **The Compose runner runs test scripts in the sandbox.** `docker-compose.yml` now starts the runner with `--sandbox`, so each test script runs in its own user and network namespace, with no network. The runner service sets `seccomp=unconfined` and `apparmor=unconfined`, because Docker's default profiles refuse `unshare`. `deploy/README.md` gives a host check to run first. A runner that cannot start the sandbox refuses to start. The change takes effect when a host's checkout is updated and the runner is restarted.
