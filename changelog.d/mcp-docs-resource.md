### Added

- **Authoring guides exposed as MCP resources.** The per-student
  solution-notebook recipe is now readable by connected agents at
  `chickadee://docs/personalization-solution-notebooks`, and the MCP server
  instructions point at that resource instead of a repo path the agent cannot
  fetch. The Docker image now ships `docs/` and the entrypoint syncs it to the
  data volume alongside Public/ and Resources/.
