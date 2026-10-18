### Fixed

- **Four MCP tools work with the dedicated MCP database pool.** With `MCP_DATABASE_USER` set, `clone_assignment` failed when the source had a reference solution or a library dataset, `create_assignment` and `clone_assignment` did not record version 1, and `get_suite` never showed the starter run. Each of these steps used a table that the `chickadee_mcp` role cannot use, so they now run on the owner pool, as the personalization seed already does. A new test stand-in, `MCPRoleDatabase`, models the role from the SQL file, so the tests run these tools as the role would.
