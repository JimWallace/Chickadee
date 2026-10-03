### Fixed

- **The MCP instructions say an assignment declares its language.** The `initialize` instructions and `set_assignment_language` still said the language was resolved from the graded scripts and the starter notebook's kernel, which #1331 removed. They now say that `create_assignment` requires the declaration, `set_assignment_language` changes it, and new content does not (#1933).
