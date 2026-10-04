### Changed

- **The two MCP surfaces share one tool registry type and one principal type.** `ToolRegistry` and `DiagnosticToolRegistry` were two structs that differed only in their element type, and `MCPPrincipal` and `AdminMCPPrincipal` differed only in their scope type. They are now `MCPToolRegistry<Tool>` and `MCPSurfacePrincipal<Scope>`, and the old names stay as typealiases. Behaviour does not change. The bearer middlewares follow in a second change (#1944).
