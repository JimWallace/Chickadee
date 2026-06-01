### Added

- **MCP personalization tools — global inputs.** The content-authoring MCP
  server now exposes `get_global_inputs` and `update_global_inputs`, letting an
  authorized agent read and replace an assignment's personalization variables
  and per-student expressions. Both drive the same `GlobalInputsService` the web
  editor uses, so identifier/`seed`/uniqueness/placeholder validation and the
  save-time expression eval run identically across surfaces.
