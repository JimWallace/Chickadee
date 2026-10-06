### Security

- **The validate_assignment progress stream reads on the MCP database pool.** The streamed `validate_assignment` call watched validation on the default database pool, so with a dedicated least-privilege MCP role configured, this one path went around the role wall that every other MCP read relies on. It now uses the same pool as `ToolContext.db`, and its audit row records the call's outcome. (#2335)
