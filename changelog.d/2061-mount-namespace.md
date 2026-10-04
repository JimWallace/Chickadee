### Security

- **A sandboxed test script no longer sees the other jobs on its runner.** With `--sandbox` on Linux, each script now also runs in a private mount namespace: the work root is covered by an empty tmpfs, and only the script's working directory and the directories its environment names (`CHICKADEE_OPPONENT_DIR`) are bound back. On macOS the profile denies the work root and allows the same directories. The startup probe checks the mounts too, so a host that refuses them is reported before any job is claimed (#2061).
