### Changed

- **The user-row foreign-key table lists every reference.** `docs/operational-diagnostics.md` said its table listed every column that references `users.id`, but it left out the LTI, GitHub, MCP, slip-day, extension, override, version, export and activity references. The table now lists all of them. (#2283)
