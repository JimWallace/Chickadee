### Fixed

- **`MCP_MODE` now drives the advertised OAuth scopes.** The two `.well-known`
  discovery documents (`oauth-protected-resource`, `oauth-authorization-server`)
  previously advertised `content:read content:write` unconditionally, even under
  `MCP_MODE=read_only` where DCR grants only `content:read`. The mismatch made
  Claude Desktop request `content:write` at `/oauth/authorize`, get refused, and
  leave the connect flow stuck on a `claude.ai` error page. `MCPMode.advertisedScopes`
  is now the single source of truth — the discovery metadata, DCR's granted
  `scope`, and the per-request scope ceiling all derive from it, so `read_only`
  advertises and grants only `content:read` and the custom-connector handshake
  completes in both modes.
