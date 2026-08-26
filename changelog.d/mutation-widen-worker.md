### Changed

- **The weekly mutation sweep now covers the whole logic tier: RunnerCore +
  Core + Worker.** ~16,500 LOC and ~2,750 mutants across 12 shards of ~66
  minutes, up from ~10,200 LOC over 8 shards. Worker's admission was measured,
  not declared: the baseline probe ran the full suite — including the 48
  timing-sensitive WorkerTests the sweep used to `--skip` — twenty times in
  the sweep's own one-process configuration, and the skip's stated reason
  dissolved into a container capability. Unprivileged, 20/20 iterations
  failed deterministically on the sandbox's `unshare` being refused;
  privileged, 20/20 passed at 11–12s flat. So `--skip WorkerTests/` is gone
  from the sweep's testArgs, Sources/Worker mutants are graded by the tests
  that cover them, and the weekly and per-PR mutation jobs both run
  `--privileged`, exactly as the worker-tests CI job already does.
