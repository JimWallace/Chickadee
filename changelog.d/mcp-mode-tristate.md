### Changed

- **MCP server gate is now three-state (`MCP_MODE`).** The content-authoring MCP
  server replaces the binary `MCP_ENABLED` flag with `MCP_MODE`, which takes
  `off` (not mounted — the default), `read_only` (mounted and authenticated, but
  `content:write` is never honored), or `read_write` (full authoring). Read-only
  is enforced as a server-wide scope ceiling clamped per request in the bearer
  middleware, so a `content:write` token issued while the server was `read_write`
  loses write the instant an operator flips to `read_only`, with no token
  revocation. `tools/list` now advertises only the tools the caller's scopes
  cover (write tools drop out in read-only mode), and both admin token minting
  and the browser OAuth consent flow cap the granted scope to the mode's ceiling.
  Operators must switch `MCP_ENABLED=true` to `MCP_MODE=read_write` (or
  `read_only`); `MCP_ENABLED` is no longer read.
