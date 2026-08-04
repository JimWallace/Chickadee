### Fixed

- **Browser probe jobs no longer time out on a cold build.** `browser-probe-setup`
  builds `chickadee-server`, and the shared build cache it restores is keyed on
  `hashFiles('Sources/**', 'Tests/**')` — so the key is new on any PR touching
  either, and the job that populates it lives in a different workflow, which
  `needs:` cannot order against. The probes therefore cold-build, and the setup
  step alone measured 23.2 min on a passing run and 29.0 min on a killed one,
  against a 30 min ceiling. The budget only ever fit the cache-hit path; on a
  miss the job died in setup with every test step `skipped`, and GitHub reports
  a timeout-kill as `cancelled`, which reads as an unrelated concurrency cancel.
  Budgets raised to 50 min (75 for the grading probe, which runs 12 iterations
  per engine on top of the same setup).
