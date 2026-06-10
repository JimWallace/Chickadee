### Added

- **MCP instructions/catalog drift guard.** New tests assert every tool in the
  live MCP catalog is mentioned in the server-level `initialize` instructions
  and declares a description, an object `inputSchema`, an `outputSchema`, and
  annotations consistent with its required scopes — turning the "keep the
  agent-facing copy in sync with the catalog" convention into a build failure.
