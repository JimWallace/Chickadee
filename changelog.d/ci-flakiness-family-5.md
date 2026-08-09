### Changed

- **`docs/ci-flakiness.md` gains Family 5: `api-tests` starved past its
  20-minute ceiling.** A `cancelled` `api-tests` job looks identical to the
  #1233 wedge but can be plain starvation — the tell is whether tests were
  still *completing* at the tail of the log, and whether `api-tests-postgres`
  (same target, same commit) passed. Recorded with the measurement that
  separates the two: the same commit's `Run APITests` step took 1107 s
  (killed at the ceiling) and 216 s on rerun, against a `main` baseline of
  204/236/441 s min/median/max over 18 runs. Notes two structural findings —
  the sqlite lane has both the wider run-to-run spread and the tighter
  ceiling, and `WedgeWatchdog` is `WorkerTests`-local, so APITests carries
  `.timeLimit` (which cannot fire under pool saturation) and not the guard
  that can. The CLOEXEC residual in attack-order item 3 is reclassified from
  "cosmetic" accordingly.
- **`api-tests` gets the same 25-minute CI ceiling as `api-tests-postgres`.**
  The two run the same target; the sqlite lane had the tighter cap despite
  the wider run-to-run spread. This buys headroom for the ordinary tail, not
  for a starvation event — the job that prompted it was killed still running
  at 1107 s, and nothing establishes it would have finished inside the larger
  budget either.
