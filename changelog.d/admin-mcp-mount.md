### Added

- **Admin diagnostic MCP — HTTP mount + bearer auth (internal).** The read-only
  admin diagnostic surface (`docs/admin-mcp.md`) is now mountable at
  `POST /admin-mcp` behind `ADMIN_MCP_MODE=read_only`, with its own
  `AdminMCPBearerAuthMiddleware` (separate ES256 signing key + token audience
  from the content surface, so a content token can't call admin tools), an
  RFC 9728 protected-resource discovery document, the production DNS-rebinding
  fail-safe, and per-call audit (`admin_mcp.tool_called`). Off by default; OAuth
  consent issuance lands in a follow-up, so it's reachable only with a
  directly-minted admin token for now.
