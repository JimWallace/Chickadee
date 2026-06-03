### Fixed

- **WorkerTests is more reliable under parallel CI load.** The suite spawns
  real `/bin/sh` and `python3` subprocesses, which Swift Testing runs in
  parallel, so a cold-cache nightly could fork enough at once to trip a
  transient `posix_spawn` failure or starve a daemon polling task. A shared
  `withSubprocessSlot` throttle now bounds concurrent real-process launches
  process-wide, and every `ScriptRunner` call routes through `runScriptRobustly`
  — generalizing the #787 launch-failure retry (previously on just two tests)
  to the whole suite. The retry fires only on the empty "never launched"
  sentinel, so a genuine regression is never masked. The three hand-rolled
  `python3 http.server` helpers in `WorkerDaemonTests` are unified into one
  `LocalHTTPTestServer` that reads the child's port with a read-until-newline
  loop (fixing a single-`availableData` truncation race) and tears down with a
  prompt `SIGKILL` (a `SIGTERM` doesn't reliably stop a `socketserver` with the
  daemon's connection still open) followed by `waitUntilExit()`. CI now
  installs `python3` explicitly for the worker-tests job.
