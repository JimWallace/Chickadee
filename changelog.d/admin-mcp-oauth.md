### Added

- **Admin diagnostic MCP — OAuth issuance (internal).** The browser OAuth 2.1
  flow (`/oauth/authorize` + `/oauth/token`) is now resource-aware: an admin can
  authorize an agent for the admin diagnostic resource (`docs/admin-mcp.md`),
  selected by the RFC 8707 `resource` parameter or the requested scope namespace
  (`diagnostics:read`). The flow branches the scope ceiling, role gate
  (`isInstructor` for content, `isAdmin` for diagnostics — re-checked at consent
  and on every refresh), signing key, and audience by resource, with no schema
  change (the disjoint `content:*` / `diagnostics:*` namespaces identify the
  surface at every step). The content authoring flow is unchanged. Note: the
  shared authorization server mounts with `MCP_MODE`, so admin OAuth issuance
  currently requires the content MCP endpoint to also be enabled.
