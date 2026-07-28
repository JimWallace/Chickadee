### Added

- **MCP 2026-07-28 adopted — the server is now dual-era (#1218).** Chickadee
  speaks the modern, handshake-free revision alongside the legacy
  `initialize` revisions (`2025-11-25` / `2025-06-18`) on the same endpoint,
  choosing per request from how the client opens: a body carrying
  `io.modelcontextprotocol/protocolVersion` in `_meta` gets the modern
  semantics, anything else keeps the existing behaviour byte for byte. Both
  MCP servers implement it — the content authoring surface (`/mcp`) and the
  admin diagnostic surface (`/admin-mcp`).

  What that means on the wire: the mandatory **`server/discover`** method
  returns supported versions, capabilities, and instructions (including the
  caller's per-course authoring guidance) in one call; every modern result
  carries the required `resultType` discriminator plus
  `_meta['io.modelcontextprotocol/serverInfo']`; the mirrored
  `MCP-Protocol-Version` / `Mcp-Method` / `Mcp-Name` headers are validated
  against the request body (base64 sentinel decoded first) so an intermediary
  cannot route on one value while the server acts on another; and the
  revision's protocol errors are HTTP-visible — `-32022`
  UnsupportedProtocolVersion (listing supported versions so a client can
  retry), `-32020` HeaderMismatch, and malformed `_meta` are `400`, while an
  unimplemented method is `404`.

  `initialize` deliberately never negotiates up into the modern revision: a
  legacy client that asks for `2026-07-28` is answered `2025-11-25`, since a
  client using the handshake cannot speak the per-request protocol. Design,
  the corrections to the earlier release-candidate analysis, and the
  per-request era table are in `docs/mcp-2026-07-28-revision.md`.
