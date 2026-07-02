### Changed

- **MCP boilerplate deduplicated (#1121).** The surface-agnostic halves of MCP
  dispatch — tools/list entry encoding, spec pagination, the tools/call result
  envelopes, and initialize version negotiation — now live once in
  `MCPDispatchShared.swift`, shared by the content and admin dispatchers (a
  protocol-version bump or error-envelope change is a one-place edit). The
  hand-written JSON-schema literals that repeated across the tool catalog
  (`assignmentPublicID` ×29, bare-typed output properties ×212, the tier enum
  ×7, `courseCode` ×5) are now `MCPSchema` constants/builders, and a new
  `MCPOutputSchemaSyncTests` guards output-schema/`Output`-struct drift
  (structural check over the whole catalog + representative-instance key sync
  for the drift-prone write tools). The cross-cutting single-field manifest
  helpers moved out of `CourseSectionTools`/`SetTimeLimitTool` into
  `Helpers/ManifestFieldEdits.swift`, expressed as `mutateManifest` closures.
