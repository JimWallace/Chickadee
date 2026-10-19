### Fixed

- **`run_tournament` works with the dedicated MCP database pool.** With `MCP_DATABASE_USER` set, the `chickadee_mcp` role could not see the students' submissions, so `run_tournament` always refused with "at least two students" and found 0. It could also not write the run. The tool now starts the run on the owner pool. It still returns only the number of entrants and rounds.
