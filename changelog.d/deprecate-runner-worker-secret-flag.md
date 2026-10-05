### Deprecated

- **The runner's `--worker-secret` flag.** It puts the runner secret in the runner's command line, and every test script can read that command line from `/proc`, also inside the sandbox. With the secret, a script can sign worker API calls, for example to report its own result. The runner now prints a deprecation warning when the flag is set, and the next minor release removes it. Set `RUNNER_SHARED_SECRET` instead.

### Security

- **The runner refuses `--worker-secret` together with `--sandbox`.** A runner started with both flags exits at startup and says why, because the flag defeats the isolation that `--sandbox` asks for.
