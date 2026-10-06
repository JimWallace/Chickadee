### Fixed

- **One MCP error policy on both surfaces.** A refusal from a shared web helper (4xx) reaches the agent with its reason, and a server fault (5xx) stays opaque to the agent and is logged. Seven MCP tools converted a 5xx into a visible, unlogged tool error, and the admin surface mapped nothing, so a refusal there reached the agent as an opaque internal error. (#2338)
