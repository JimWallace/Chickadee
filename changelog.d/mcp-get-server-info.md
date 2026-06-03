### Added

- **MCP `get_server_info` tool.** A read-only tool that reports the deployed
  Chickadee version, the active MCP mode (`read_only` / `read_write`), the
  advertised content scopes, and whether writes are honored. Because a tool
  *call* round-trips to the running process, it answers "is this deploy live
  yet?" unambiguously even when a client has cached the `initialize` result or
  `tools/list` catalog — and doubles as a capability probe so an agent can tell
  whether write tools will work before calling one. DB-free, so it stays a
  useful liveness check even if the database is unavailable.
