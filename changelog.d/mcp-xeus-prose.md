### Fixed

- **The MCP tools name the xeus kernels, not Pyodide.** `get_assignment`, `set_grading_mode` and the admin `get_browser_diagnostics` still said browser grading runs on Pyodide, which was removed in v0.5.19. The `initialize` instructions also gave Python's import-quarantine rule for every notebook; it now applies to Python notebooks only, because a notebook in any other language is extracted verbatim (#1934).
