### Added

- **Auto-deploy daemon (`deploy/chickadee-deployer.sh` + systemd unit).** Phase 2
  of zero-downtime deploys: a small host-side shell daemon polls GitHub Releases
  and blue-green-deploys each new version automatically via
  `scripts/bluegreen-deploy.sh`. Non-major bumps ship on their own; **major bumps
  are held for human approval** (configurable `DEPLOY_GATE_LEVEL=major|minor`).
  Each deploy is preceded by a `snapshot.sh` safety net and followed by a short
  public-health verification that auto-rolls-back if the new release degrades
  after the cutover. It never forces a swap (relies on the symlink guard, so a
  not-yet-converted volume fails safe), and writes `status.json` / `history.jsonl`
  to the shared state dir — and reads pause/resume/approve/rollback commands from
  `command.json` — for the planned admin-MCP oversight surface (Phase 3). The app
  container never touches Docker; the daemon is the sole holder of docker/nginx
  privileges. See `docs/zero-downtime-deploy.md`.
