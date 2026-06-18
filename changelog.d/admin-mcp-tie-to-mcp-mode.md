### Changed

- **Admin diagnostic MCP tied to `MCP_MODE` (no separate config).** The admin
  diagnostic surface (`docs/admin-mcp.md`) no longer has its own `ADMIN_MCP_*`
  environment variables. It now mounts (read-only) exactly when the content MCP
  is mounted via `MCP_MODE` (`read_only` or `read_write`) — all-or-nothing — and
  reuses the content surface's host/origin guards, issuer, access-token TTL, and
  ES256 signing key/authority (the two surfaces are separated by token audience,
  `…/mcp` vs `…/admin-mcp`, not by a second key). It stays read-only even under
  `MCP_MODE=read_write` (it only ever advertises/honors `diagnostics:read`).
  `AdminMCPConfig` / `AdminMCPMode` are removed.
