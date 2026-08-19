### Fixed

- **The `student` test tier never existed, and the MCP surface offered it anyway.**
  `TestTier` has three cases — `public`, `release`, `secret` — but the MCP schema
  enum and thirteen hand-typed strings advertised a fourth. An agent could pass
  `student` through JSON Schema validation and then be rejected one layer down by
  `TestTier(rawValue:)`, with an error message that listed the same impossible
  value back at it; the web suite editor meanwhile coerced an unrecognized tier to
  `public` rather than refusing it, so one door silently changed the value and the
  other refused it. The tier is gone from the schema and the prose, and the prose
  is now derived from `TestTier.allCases` (`MCPTierProse`) rather than typed, so
  neither a phantom nor a truncated list can come back.

### Changed

- **Tier prose in the MCP surface is derived, and guarded.** `MCPTierCoverageTests`
  scopes to the whole served catalog, the way the language guards do: it fails if
  the schema advertises a tier the parser refuses, if a real tier is unadvertised,
  or if any served text continues a correct tier list with its own separator (a
  phantom) or stops short of it (a truncation).
