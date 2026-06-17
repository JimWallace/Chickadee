### Added

- **MCP `reorder_assignments` tool.** Agents can now set the instructor-defined
  display order of a course's assignments — the assignment-level counterpart to
  `reorder_course_sections`, mirroring the web dashboard's drag-reorder. Takes a
  full permutation of the course's assignment public IDs and rewrites the
  course-global `sort_order`; it's organizational metadata, so it never re-runs
  validation or changes an assignment's open/closed state.
