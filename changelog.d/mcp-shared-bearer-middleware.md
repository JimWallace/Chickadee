### Changed

- **The two MCP surfaces share one bearer middleware.** `MCPBearerAuthMiddleware` and `AdminMCPBearerAuthMiddleware` were two copies that differed only in how they grant scopes. They are now `MCPSurfaceBearerAuthMiddleware<Scope>` with a per-surface scope ceiling, and the old names stay as typealiases with their old initializers. The content surface still clamps to the MCP_MODE ceiling on every request; the admin surface still grants only `diagnostics:read`. Behaviour does not change (#1944).
