### Security

- **MCP OAuth single-use tokens are now burned atomically.** The authorization
  code, the consent token, and refresh-token rotation each consumed their
  single-use record with a read-check-then-save, leaving a small TOCTOU window
  where two concurrent `POST /oauth/token` (or `/oauth/authorize`) requests for
  the same code could both succeed and mint two token pairs. Consumption is now
  a single conditional `UPDATE … WHERE consumed = false RETURNING` (atomic on
  both SQLite-WAL and Postgres), so only one caller can ever win.

### Fixed

- **MCP OAuth hardening.** Token-endpoint error and dynamic-registration error
  responses (and the consent page) now send `Cache-Control: no-store`; the
  hourly OAuth reaper now also drops consumed-but-unexpired authorization codes
  and consent requests; and a new index on
  `oauth_grants.previous_refresh_token_hash` keeps refresh-token theft detection
  and `POST /oauth/revoke` off a full table scan as long-lived grants accumulate.
