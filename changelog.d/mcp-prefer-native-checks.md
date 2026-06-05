### Changed

- **MCP authoring steers agents toward native check types.** The server
  `initialize` instructions, the `author_script` tool description, and the
  `create_pattern_family` / `author_notebook_check` descriptions now frame
  hand-written scripts as a last-resort escape hatch and point agents at pattern
  families and notebook checks — which are validated structurally on save,
  personalize per student, and can be read back via `get_suite` — for graded
  tests. Guidance copy only; no behaviour or schema change.
