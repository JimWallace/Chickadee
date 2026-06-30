### Security

- **Block MCP content writes to archived courses (#417 Slice D-MCP).** Slice C
  added the archived-course write block to a single MCP tool
  (`set_assignment_course_section`); this extends it across **every** MCP
  content-write tool. A new `ToolContext.authorizeCourseWriteAccess` chokepoint
  (per-course access + archived block, admin-exempt) backs write-only resolvers
  — `authorizedAssignment[AndSetup]ForWrite`, `resolveCourseIDForWrite`, and the
  now-write-gated `resolveCourseSectionForEdit` — so suite/script/family/check
  edits, notebook + solution updates, grading-mode/time-limit/achievements/
  global-input/section-variable changes, assignment create/clone/update,
  reorders, and course-section CRUD all reject a write driven by id into an
  archived (read-only) course. Critically, the **read** tools (`get_suite`,
  `get_notebook`, `get_achievements`, `get_global_inputs`, `get_support_files`,
  `preview_personalization`, `list_course_sections`) keep using the read
  resolvers, so archived courses stay readable for audits/lookups — the naive
  "add the block to the shared resolver" approach would have 403'd those reads.
  Clone blocks on the **destination** course only, so reviving an archived
  course's content into a live course still works. Admins remain exempt.
