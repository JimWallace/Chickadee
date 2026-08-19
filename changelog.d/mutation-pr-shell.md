### Fixed

- **The per-PR mutation job could never run.** `mutation-pr.yml` runs in a
  container, where the resolved default shell is `sh`, but two of its steps are
  bash — `mapfile` with process substitution to read the include globs, and array
  building to assemble the `--file` list. Under dash the first died at parse time
  with "Syntax error: redirection unexpected", before working out which files to
  mutate. The job now declares `shell: bash`. It had never been exercised: the
  workflow only triggers on `Sources/RunnerCore/**`, and the first PR to touch
  that since it was added is the one that found this.
