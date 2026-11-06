### Changed

- **Where the grading mode is chosen, a browser grade now reads as a participation grade (#2240).** The course-section mode selector offers "Student Browser (participation grade)", the new-assignment hint says the section grades in the student's browser for a participation grade, the MCP `set_grading_mode` and `create_course_section` descriptions tell an agent to choose `worker` for work whose grade must be correct, and `docs/architecture.md` states the rule. This is the last step of `docs/grading-integrity.md` D8; no grading behaviour changes.
