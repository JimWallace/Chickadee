### Added

- **Deploy oversight on the admin MCP surface (Phase 3).** Two read-only admin
  diagnostic tools — `get_deploy_status` (the auto-deploy daemon's current state:
  live version, latest release seen, paused flag, pending-major-approval) and
  `get_deploy_history` (recent deploy / gate / rollback events) — let an
  operator or agent see deploy state remotely. They read the daemon's
  `status.json` / `history.jsonl` from `Application.deployStateDirectory`
  (`CHICKADEE_DEPLOY_STATE_DIR`, default `/deploy-state`), which the blue-green
  script now mounts into the container **read-only** — so the app can see deploy
  state but physically cannot write `command.json`, and can never move traffic.
  Deploy *control* (pause/approve/rollback) stays a host-side action, preserving
  the admin surface's read-only-by-construction guarantee. See
  `docs/zero-downtime-deploy.md`.
