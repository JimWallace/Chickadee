### Changed

- **A shared kit for the MCP tool tests (#2716).** `Tests/APITests/MCPToolTestKit.swift` holds `mcpContext`, `seedMCPCourse`, `seedMCPAssignment` and `mcpTestUser`. The MCP suites use it in place of their copied context and fixture helpers. A new contract test, `MCPEnrollmentDenialContractTests`, runs every tool in `MCPToolCatalog.live` as an enrolled account and as an unenrolled account, and makes sure that each tool refuses the unenrolled account. It replaces 22 copied denial tests, and adds enrollment coverage for the tools that had none.
