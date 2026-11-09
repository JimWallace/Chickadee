### Fixed

- **MCP results carry the required caching fields.** On the 2026-07-28
  protocol revision, `server/discover`, `tools/list`, `resources/list` and
  `resources/read` now send `ttlMs: 0` and `cacheScope: "private"`, which the
  schema requires on each of them. Without them Claude Code rejected the tool
  list after a successful sign-in, so both MCP surfaces connected but offered
  no tools.
