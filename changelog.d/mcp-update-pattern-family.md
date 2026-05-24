### Added

- **MCP authoring (write): `update_pattern_family` tool.** Lets an authorized
  agent edit a pattern family's metadata for an assignment — its default tier
  and points, and which cases are enabled — by assignment public ID + family id.
  A targeted read-modify-write through the same suite-edit path the web editor
  uses: every other field (function, params, case args/expected/variables) is
  preserved verbatim, and saving regenerates the family's scripts and re-runs
  validation. It does **not** author case args or expected values (the test
  logic itself).
