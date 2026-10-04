### Changed

- **An MCP tool error takes the tool's name from the call, not from the tool.** `MCPToolError` no longer carries a `tool` field, and 34 helpers no longer take a `tool:` parameter; tools passed their own name by hand 336 times. The dispatcher passes `call.name` to `mcpToolErrorResult`, so every error names the tool that was actually called. The two `atLeast: CourseRole = .instructor` defaults in `CourseSectionTools.swift` are gone too, as `ToolContext` already required; their callers now say `.instructor` (#1939).
