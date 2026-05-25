### Security

- **Hardened MCP server test coverage.** Added regression tests pinning the MCP
  security guarantees surfaced in the audit: `/agents` cross-tenant authorization
  (instructors list/revoke only their own grants, admins all — no IDOR),
  OAuth authorization codes are single-use, the bearer gate rejects wrong-issuer
  and bad-signature tokens, the `/mcp` Host allowlist rejects a disallowed Host,
  Dynamic Client Registration honors its client cap, and no MCP/OAuth/discovery
  routes are mounted when `MCP_ENABLED` is false.
