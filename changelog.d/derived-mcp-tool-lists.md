### Fixed

- **Two MCP tool descriptions name every case of their lists again.** `author_script` described seven of the ten pattern kinds, and its notebook-check summary left out two kinds. `get_health_alerts` named six of its nine rules, although it reports all nine. Both lists now come from the enums (`PatternKind`, `NotebookCheckKind` and `HealthRule`), so a new case appears without an edit. This is part 1 of #1935.
