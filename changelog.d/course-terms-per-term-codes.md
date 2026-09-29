### Changed

- **Course codes are unique per term.** Two active offerings of one course, such as CS135 Fall 2026 and CS135 Winter 2027, can now share a code. A course with a term uses the URL segment `CS135-F26`. An old link with the bare code opens the offering the viewer is enrolled in, else the newest term. MCP tools accept the code or the key, report each course's term and key in `list_courses`, and refuse a write through a code that names more than one offering. See `docs/course-terms.md`.
