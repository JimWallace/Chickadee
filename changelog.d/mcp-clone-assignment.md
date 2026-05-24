### Added

- **MCP authoring (write): `clone_assignment` tool.** Lets an authorized agent
  duplicate an existing assignment — its test setup (scripts, manifest, pattern
  families) and notebook copied verbatim — into a new assignment by source
  public ID + new title, optionally into another course the account is enrolled
  in. The safe first cut at assignment creation (roadmap Phase 4a): the clone
  lands closed, unvalidated, and with no due date, then the agent tweaks it with
  `update_suite` / `update_pattern_family` / `update_assignment`. Backed by the
  same per-assignment copy the admin "copy course" flow uses, so the two paths
  can't drift; nothing is re-graded.
