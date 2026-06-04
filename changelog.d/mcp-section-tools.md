### Added

- **MCP section-management tools.** The content-authoring MCP server can now
  organize both tests and assignments. `create_section` / `rename_section` /
  `delete_section` manage an assignment's test-suite display sections, and
  `move_suite_item` places a script, pattern family, or notebook check into a
  section (or ungroups it), reordering the suite so each section stays a
  contiguous block — covering families and checks, which `update_suite` could
  not move. `list_course_sections` / `create_course_section` /
  `set_assignment_section` manage the course-level assignment groups (e.g.
  "Labs"); `set_assignment_section` adopts the section's default grading mode,
  matching the web dashboard. `get_assignment` now reports which course section
  an assignment belongs to.
