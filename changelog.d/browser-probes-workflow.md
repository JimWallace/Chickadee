### Changed

- **The six browser probe workflows are one workflow, `browser-probes.yml`,
  with one server build.** A job can only depend on a job in its own workflow
  run, so the six workflows built `chickadee-server` six times. Now one
  `server` job builds it for every probe leg. A `changes` job decides which
  probes run: on a pull request by each probe's own paths, as before; on a
  schedule by its cron (the editor smoke daily, the grading-hang probe
  weekly); on a dispatch by a new `probes` input. The job names did not
  change, so `editor-smoke-gate` is still the required check.
  `flake-telemetry.yml` now reads the combined workflow and counts a red run
  for a probe only when that probe's own legs failed.
