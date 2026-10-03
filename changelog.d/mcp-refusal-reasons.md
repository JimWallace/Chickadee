### Fixed

- **Every MCP tool reports a refusal's reason.** A refusal from a shared web path (a `WebAssignmentError` or a Vapor `Abort` with a 4xx status) reached the agent with its reason only from the tools that mapped it themselves. `set_grading_mode`, `set_time_limit` and `set_minimum_runner_version` did not, so the agent saw an opaque internal error. The tool erasure now maps every 4xx refusal for every tool; a 5xx stays opaque to the agent and is logged (#1940).
