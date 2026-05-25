### Added

- **MCP authoring (write): `create_assignment` tool.** Lets an authorized agent
  create a brand-new browser-graded, notebook-based assignment from scratch in a
  course, by course code + title + starter notebook (.ipynb JSON). Assembles a
  minimal empty-suite manifest + an empty runner zip + the notebook through the
  shared authoring service (the same per-setup work the web new-assignment
  publish does, minus the draft scaffolding), then a fresh assignment row that
  lands closed, unvalidated, and with no due date. The agent fills in tests with
  `update_suite` / `update_pattern_family` and refines the notebook with
  `update_notebook`, then opens it. Completes the assignment-authoring tool set
  alongside `clone_assignment`. `content:write`, course-scoped.
