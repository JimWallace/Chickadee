### Security

- **The Compose runner no longer mounts the data volume.** It mounted
  `chickadee-data` read-only for one reason: to read `/data/.worker-secret`.
  That volume also holds the SQLite database, every submission, and the results
  tree, and a test script runs as the same uid as the runner — so the secret
  file's `0600` mode was no barrier. A student script could read the runner ↔
  server HMAC secret and sign worker API calls, which is exactly what the
  environment allowlist in `mergedScriptEnvironment` withholds it to prevent,
  and could read student submissions and the database directly. Enabling
  `--sandbox` would not have closed either hole: the Linux sandbox isolates the
  network, not the filesystem. The secret now arrives through
  `RUNNER_SHARED_SECRET`, which both the server and the runner already read and
  which the server already prefers over the persisted file, so the runner
  container has no access to student data at all.

### Changed

- **`RUNNER_SHARED_SECRET` is required for Docker Compose.** It is now the only
  channel by which the runner container learns the secret, so Compose fails
  fast with a pointed message when it is unset rather than starting a runner
  that cannot authenticate. Generate one with `openssl rand -base64 32`. A
  deployment with no separate runner container may still leave it unset and
  fall back to the auto-generated `.worker-secret`.
