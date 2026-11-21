### Added

- **Tests for the runner start command and the job cgroup fallback.** New worker tests start `chickadee-runner` end to end (an invalid API base URL, a missing secret, a start that drains on SIGTERM), check the sandbox-on startup checks, and check that a command whose job cgroup cannot be created is still graded and leaves no cgroup behind.
