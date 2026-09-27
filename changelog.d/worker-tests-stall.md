### Fixed

- **`worker-tests` no longer stalls until its CI ceiling.** The test HTTP server launched its Python processes through Foundation's `Process`, whose exit signal could leak into a sibling server and leave `stop()` waiting forever on a shared thread. It now launches them through Subprocess, and `stop()` never waits. The wedge watchdog also writes its thread table to a file that the lane prints on failure or cancel. See `docs/ci-flakiness.md`, Family 6.
