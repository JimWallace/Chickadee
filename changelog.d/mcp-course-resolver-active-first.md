### Fixed

- **The MCP course resolver matches active courses before archived ones.** It matched over every course and then kept the active subset only when non-empty, so an archived legacy course coded "CS243-F26" won that key over an active CS243 in Fall 2026, while the web resolver chose the termed course. Both now agree (#1778).
