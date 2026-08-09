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
  glibc 2.39 both spawners this codebase uses already prevent it — a pipe of
  ours does not survive into a child spawned through Foundation's `Process`,
  and swift-subprocess `close_range`s everything above stderr — so only a bare
  `posix_spawn` still inherits. Kept as defence in depth and as the invariant
  every other pipe here already states; `PipeCloseOnExecTests` pins the
  measurement, and its control fails if the leak ever stops being
  demonstrable.

- **`docs/ci-flakiness.md` gains Family 5: `api-tests` starved past its
  20-minute ceiling.** A `cancelled` `api-tests` job looks identical to the
  #1233 wedge but can be plain starvation — the tell is whether tests were
  still *completing* at the tail of the log, and whether `api-tests-postgres`
  (same target, same commit) passed. Recorded with the measurement that
  separates the two: the same commit's `Run APITests` step took 1107 s
  (killed at the ceiling) and 216 s on rerun, against a `main` baseline of
  204/236/441 s min/median/max over 18 runs. Also records that reproducing
  `APITests` locally needs CI's
  `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4`, since unbounded
  parallelism SIGSEGVs the target in a way that reads as a regression.

- **`api-tests` gets the same 25-minute CI ceiling as `api-tests-postgres`.**
  The two run the same target; the sqlite lane had the tighter cap despite
  the wider run-to-run spread. This buys headroom for the ordinary tail, not
  for a starvation event — the job that prompted it was killed still running
  at 1107 s, and nothing establishes it would have finished inside the larger
  budget either.
