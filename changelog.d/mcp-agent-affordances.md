### Added

- **MCP server now orients connecting agents.** The `initialize` result carries
  server-level `instructions` (the domain model, the read-before-write workflow,
  and the validation/scope/safety rules), and every content tool now advertises
  an `outputSchema` for its structured result plus behavioural `annotations`
  (read-only / destructive / idempotent hints). The server also reports a
  human-friendly `title`.

### Changed

- **MCP `initialize` no longer advertises an unimplemented `resources`
  capability.** v1 announces tools only; the dormant resources endpoints remain
  as scaffolding for a later release but are no longer claimed in the handshake.
