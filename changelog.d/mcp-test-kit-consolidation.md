### Changed

- **MCP test helpers live in one kit.** The OAuth PKCE and consent helpers that five suites copied now live in `Tests/APITests/MCPOAuthTestKit.swift`, and the hand-built MCP tool and admin tool contexts use `mcpContext` and the new `adminMCPContext`.
