### Fixed

- **`clone_assignment` carries the secret-reveal, passing-threshold and sync-exclusion policies.** The course clone set the three after `cloneAssignment` returned and the MCP tool set nothing. `cloneAssignment` now copies them itself, so the two clones agree; section and sort order stay with the course clone, since sections map per course (#1738).
