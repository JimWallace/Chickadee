### Added

- **MCP 2026-07-28 spec impact & adoption plan.**
  `docs/mcp-2026-07-28-revision.md` analyzes the upcoming stateless MCP
  revision against Chickadee's MCP server: our transport is already stateless
  and OAuth 2.1/PKCE/RFC 8707/RFC 9728 compliant, so nothing breaks when the
  spec finalizes. The one concrete gap — RFC 9207 `iss` on the OAuth
  authorization response (SEP-2468) — plus the optional stateless-adoption work
  are tracked for the week of 2026-07-28 in #1218.
