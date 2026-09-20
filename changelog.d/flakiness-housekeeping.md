### Changed

- **Flakiness housekeeping.** `docs/ci-flakiness.md` records the first
  post-fix population for Family 5 (27 `main` runs, medians 144 s and 183 s,
  no run at 2× median, no ceiling kill; the symptom is absent and the cause
  still unknown) and corrects the Family 2 gate policy, which described
  scheduled hard-zero runs of `grading-hang-probe.yml` while that workflow
  had no schedule; it now runs weekly, ahead of the Monday flake tally. The
  two xeus-python migration documents moved to `docs/archive/` with the live
  state noted in `CLAUDE.md`, whose roadmap still said Python browser grading
  ran on Pyodide. Three test-support comments that described the CI runner
  as 2-core now carry the measured 4-CPU figure.
