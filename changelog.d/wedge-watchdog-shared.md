### Changed

- **`WedgeWatchdog` is shared test support, and `APITests` now arms it.** The
  watchdog — a monitor on a dedicated OS thread that dumps `/proc/self/task`
  (state + `wchan` per thread) and aborts after 300 s of total test silence —
  was `WorkerTests`-local, so an `api-tests` stall still burned a silent
  20-minute `cancelled` job and yielded nothing to diagnose from. It moves to a
  new `ChickadeeTestSupport` target that both test targets depend on (one copy,
  no drift), and `APITests` arms it at `withApp`, the scope 172 of its 315
  files funnel through. It measures silence, not slowness: entering or leaving
  any test body resets the clock, so a lane merely running at 10× cost — the
  2026-08-09 shape — still passes, while a wedge fails in ~6 minutes carrying
  the thread table that names the pinned syscalls. Verified both ways: a full
  `APITests` run passes with the limit forced down to 30 s (individual tests
  reporting up to 131 s of wall clock), and an induced pool wedge aborts with a
  dump showing four cooperative-pool threads parked in `anon_pipe_read`.

- **`FD_CLOEXEC` on the last three unguarded subprocess pipes**
  (`Core/ZipArchiver`, `TestSetupZipHelpers`, `NotebookContentHelpers`), via
  the worker's `setCloseOnExec` hoisted to `Core` so there is still exactly one
  implementation. Filed as the mechanism that makes a transient overload
  permanent; measured, it is not currently reachable that way. On Swift 6.3 /
  glibc 2.39 both spawners this codebase uses already close inherited
  descriptors themselves — Foundation's `Process` leaves a child holding only
  fds 0/1/2, and swift-subprocess `close_range`s everything above stderr — so
  only a bare `posix_spawn` still inherits. The change is kept as defence in
  depth and as the invariant every other pipe here already states; the
  measurement is pinned by `PipeCloseOnExecTests`, whose control fails if the
  leak ever stops being demonstrable.
