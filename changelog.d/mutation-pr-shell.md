### Fixed

- **The per-PR mutation job could never run.** `mutation-pr.yml` runs in a
  container, where the resolved default shell is `sh`, but two of its steps are
  bash — `mapfile` with process substitution to read the include globs, and array
  building to assemble the `--file` list. Under dash the first died at parse time
  with "Syntax error: redirection unexpected", before working out which files to
  mutate. The job now declares `shell: bash`. It had never been exercised: the
  workflow only triggers on `Sources/RunnerCore/**`, and the first PR to touch
  that since it was added is the one that found this.

- **…and then reported a false clean.** With the shell fixed, the same step's
  `git diff` failed with "Not a git repository" and the trailing `|| true` — there
  so that grep finding no Swift files is not an error — swallowed it, so an empty
  result was read as "No mutable files changed; nothing to do." on a PR that had
  changed `Sources/RunnerCore/TestTier.swift`. The step now checks it is inside a
  work tree and checks `git diff`'s own exit status, failing loudly with what went
  wrong; only grep's no-match stays a legitimate empty result. The job is
  `continue-on-error`, so a loud failure blocks nobody — it just stops a run that
  measured nothing from reading as a clean bill of health.
