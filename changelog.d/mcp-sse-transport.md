### Added

- **MCP Streamable HTTP: SSE response mode.** The `/mcp` POST now honours
  `Accept: text/event-stream` and returns the JSON-RPC response as a Server-Sent
  Events stream (one `event: message` framing the result), instead of plain
  JSON, which is what the Claude connector speaks. Content negotiation is the
  only change — the dispatched result is identical, and clients that don't ask
  for SSE still get `application/json`. The shape is forward-compatible:
  `notifications/progress` events can later precede the response without
  changing the tool contract. The transport stays stateless (no
  `Mcp-Session-Id` / `Last-Event-ID` resumability), and security-status
  responses (insufficient-scope 403, parse-error 400) are never masked behind a
  200 SSE body. Ships with `X-Accel-Buffering: no` on the stream plus a dedicated
  `location /mcp` block (`proxy_buffering off`) in both bundled nginx configs so
  events aren't held back by reverse-proxy buffering.
