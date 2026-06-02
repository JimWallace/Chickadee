### Added

- **MCP `get_suite` returns full test definitions.** The `get_suite` tool now
  surfaces each item's source of truth alongside its metadata: hand-written
  scripts include their raw body (`content`) and `hint`, pattern families
  include the full spec with every case's `args`/`expected` (`family`), and
  notebook checks include their spec (`check`). This lets an authoring agent
  read exactly what a test checks — e.g. to explain why a submission lost
  points — without leaving the read-only `content:read` scope. Exposes only
  authoring content the instructor already sees in the browser suite editor; no
  student, grade, or submission data is involved.
