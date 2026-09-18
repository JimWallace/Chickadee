### Fixed

- **Backups and restores now find the live server under blue-green.**
  `snapshot.sh` and `restore.sh` located the running server with
  `docker compose exec server` / `docker compose ps -q server`. Blue-green
  replaced the Compose `server` service with colour containers started by
  `docker run`, so both lookups returned nothing — silently. `snapshot.sh` then
  fell through to `.env`, resolved `DATABASE_BACKEND` to its `sqlite` default on
  a Postgres host, and refused to run; one deployment lost 82 consecutive
  nightly backups to this and logged the same refusal every night into a file
  nobody read. `restore.sh` wrote blank `build_version` / `image_digest` into
  every manifest, leaving its version gate comparing `VERSION` files — which
  track the git checkout rather than the deployed image, and diverge routinely
  on a host whose deployer pulls `:latest` while its clone follows `main`.
  Both now resolve the live server through a shared helper that understands
  both deployment shapes.

- **A restore no longer reloads the database underneath a running server.**
  `restore.sh` issued `docker compose stop server`, a no-op on a blue-green
  host, so the live container kept serving and writing while the schema was
  dropped and reloaded. It now stops every running server container — both
  colours, including the drained one kept for rollback — and restarts exactly
  what it stopped with `docker start`, rather than `compose up -d server`, which
  on such a host would create a rogue Compose container racing the colours
  nginx routes to.

- **The deploy scripts read `docker-compose.override.yml` again.** Compose
  suppresses the override file whenever `-f` is passed explicitly, which
  `bluegreen-deploy.sh` and `chickadee-deployer.sh` must do. Since
  `resolve_env_file` supplies the new container's entire environment, a
  deployment that kept its host-specific configuration in an override file
  would have booted the server on the base file's defaults.

- **The runner no longer reports itself permanently unhealthy.** The image
  carries one `HEALTHCHECK` that curls `/health` on `:8080`; the runner serves
  no HTTP, so it failed every 15 seconds while polling and grading normally.
  A red health flag beside a working service trains an operator to discount the
  column. Runner liveness is reported by heartbeat, which is what the
  `runnerOffline` rule and the admin dashboard read.
