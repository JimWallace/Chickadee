### Changed

- **MCP authoring enforces the per-course TA vs instructor line (#417).** The MCP
  write tools now mirror the web floors: content-editing tools (scripts, suites,
  pattern families, notebook checks, solution, notebook, inputs, achievements,
  time limit, suite sections, delete/move suite items) require the per-course
  `.ta` role, while course lifecycle/structure tools (create/clone assignment,
  `update_assignment` title/due/open state, `set_grading_mode`, assignment
  ordering, and course-section create/rename/delete/reorder/assign) require
  `.instructor`. Previously every MCP write funneled through a single
  enrollment+archived gate with no per-course role check, so an agent acting for
  a TA had the same authority as one acting for an instructor. `authorizeCourseWriteAccess`
  gains an `atLeast:` floor (default `.ta`); admins still bypass.
