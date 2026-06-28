### Added

- **Blue-green deploy script (`scripts/bluegreen-deploy.sh`).** Phase 1 of
  zero-downtime deploys: brings a new image up as an idle "color" container
  beside the live one, health-checks it on its own port, flips the host nginx
  upstream to it, drains, then stops the old color — the live service is never
  stopped before the new one is proven healthy. Runs alongside the existing
  compose stack (no `docker-compose.yml` changes); resolves the server
  environment from compose so there is no config duplication. Ships with
  `deploy/nginx-chickadee-upstream.conf` (the rewritable upstream include) and a
  full design + runbook in `docs/zero-downtime-deploy.md`, which also lays out the
  planned host deployer daemon (automatic CD gated on GitHub-release SemVer) and
  the admin MCP oversight surface.
