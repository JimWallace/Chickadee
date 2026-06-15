### Security

- **MCP server security & privacy hardening for the UW Information Risk
  Assessment.** The MCP tool surface now reaches the submissions/results tables
  only through a single validation-filtered boundary (`MCPStudentDataBoundary`),
  with a build-failing guard test if any tool handler reads student data
  directly — making the student-data wall architectural rather than
  convention. Every `mcp.tool_called` audit entry now records the call outcome
  and target resource (assignment/course), while still never logging tool
  arguments. The auto-generated MCP signing key is git-ignored, and new guard
  tests cover per-resource authorization on every tool and restrict
  reference-solution egress to `get_solution`. Adds the pre-approval audit
  artifacts under `docs/compliance/`.
