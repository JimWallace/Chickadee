### Added

- **Startup warning for an unguarded MCP transport.** Mounting `/mcp` in
  production with `MCP_ALLOWED_HOSTS` / `MCP_ALLOWED_ORIGINS` unset now logs a
  warning naming the unset variable(s) — an empty allowlist disables the
  corresponding Host/Origin DNS-rebinding guard — instead of silently
  accepting any value. Development and testing stay quiet, where empty
  allowlists are the normal default.
