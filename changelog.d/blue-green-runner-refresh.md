### Fixed

- **Blue-green deploys now refresh the Compose runner.** The zero-downtime swap
  (`bluegreen-deploy.sh`) only replaces the server color containers, so the
  Compose `runner` was left grading on whatever image it last started with — its
  `runnerVersion` drifted behind the server release after release. The deployer
  daemon (`chickadee-deployer.sh`) now pulls the just-deployed image and recreates
  the runner (`docker compose up -d --no-deps <runner>`) after a verified-healthy
  swap, so the runner stays in lockstep with the server. The step is best-effort
  (a runner hiccup is logged to `history.jsonl` but never rolls back the deploy)
  and can be disabled with `CHICKADEE_REFRESH_RUNNER=0`. Manual
  `bluegreen-deploy.sh deploy` users should run the same `docker compose pull
  runner && docker compose up -d --no-deps runner` afterward (now documented in
  `docs/zero-downtime-deploy.md`).
