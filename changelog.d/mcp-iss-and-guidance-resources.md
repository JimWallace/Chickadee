### Security

- **RFC 9207 `iss` on OAuth authorization responses (#1218, SEP-2468).** Every
  `/oauth/authorize` redirect — success and error, content and admin surface —
  now carries the `iss` parameter with the resolved surface's issuer, and the
  RFC 8414 authorization-server metadata advertises
  `authorization_response_iss_parameter_supported: true`, so updated MCP
  clients can validate the issuer and detect mix-up attacks. The value always
  matches the `iss` claim of the token subsequently minted for that surface.

### Added

- **Authoring guidance exposed as live MCP resources.** The default
  authoring-voice guide is now readable at `chickadee://docs/authoring-voice`
  (served from the same constant the `initialize` instructions embed, so the
  two can never drift), and every course an agent can author in serves the
  guide actually in force for it at
  `chickadee://course/<code>/authoring-guidance`, scoped by the same
  authoring-authority resolver as the initialize embedding. Unlike the
  initialize copy (frozen per connection), the resources serve the live text,
  so guidance edits reach connected agents without a reconnect — and resources
  are untouched by the MCP 2026-07-28 stateless revision, making this the
  forward-stable delivery path (`docs/mcp-2026-07-28-revision.md`).
