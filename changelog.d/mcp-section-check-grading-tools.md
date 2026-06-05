### Fixed

- **Editing a test suite re-grades existing submissions again.** The live suite
  editor (`PUT /instructor/:id/suite`) stopped re-queuing student submissions
  when suite editing moved off the Save button (the v0.4.93 auto-retest only
  fired on the now-suite-free Save path). It once more automatically re-grades
  every existing student submission against the edited suite — gated on a real
  manifest change — so prior grades no longer silently reflect the old tests.
  The same gated helper backs the new MCP auto-re-grade, so the human and agent
  paths stay in lockstep.
- **MCP: `create_pattern_family` and `delete_suite_item` now close an open
  assignment on edit.** Both change what the suite grades but previously left an
  open (or preview) assignment open during the asynchronous re-validation
  window, letting students submit against a not-yet-revalidated suite. They now
  close the assignment and report `assignmentClosed`, matching every other
  content-edit MCP tool and the web Save button.

### Added

- **MCP course-section management.** New `rename_course_section`,
  `delete_course_section`, and `reorder_course_sections` tools complete the
  course-section CRUD an agent can perform (creation and assignment already
  existed), mirroring the instructor dashboard handlers.
- **MCP `set_grading_mode`.** Directly set an assignment's grading path
  (`worker`/`browser`) by public ID, instead of only as a side-effect of moving
  it into a course section. Changing the path does not re-grade, re-validate, or
  close the assignment.
- **MCP `author_notebook_check`.** Create or replace a notebook check (all ten
  `NotebookCheckKind`s — DataFrame shape/columns/equality, figure count, AST
  structure, …) by id, through the same validated `applySuiteEdit` path the web
  editor uses. Agents could already read, move, and delete checks but not author
  them.
- **MCP content edits auto-re-grade existing submissions.** After an agent edits
  a suite, pattern family, notebook check, or script, every existing student
  submission is automatically re-queued for grading against the new suite — the
  automatic equivalent of the instructor "Retest all" button. Gated on a real
  manifest change (so no-op edits don't fan out) and idempotent against in-flight
  retests. Pure placement edits (`move_suite_item`) and metadata edits
  (`set_grading_mode`, section organization) do not re-grade.

### Changed

- **BREAKING (MCP): suite-section tool names are now explicit.** `create_section`
  / `rename_section` / `delete_section` → `create_suite_section` /
  `rename_suite_section` / `delete_suite_section`, and `set_assignment_section` →
  `set_assignment_course_section`, so the test-suite-section tools and the
  course-section tools are unambiguous at a glance (e.g. `create_suite_section`
  vs `create_course_section`). The MCP authoring surface has no external
  consumers yet, so no migration is provided.

- **MCP grading-mode reporting is consistent.** `set_assignment_course_section` now
  reports a missing manifest `gradingMode` as `"worker"` (matching
  `get_assignment` and `TestProperties`' default) instead of null.
- **MCP docs/instructions refreshed.** The `initialize` instructions now list
  `create_pattern_family`, `delete_suite_item`, `author_notebook_check`,
  `set_grading_mode`, and the course-section tools in the recommended workflow;
  `docs/mcp-authoring-roadmap.md` lists the full thirty-four-tool catalog.
