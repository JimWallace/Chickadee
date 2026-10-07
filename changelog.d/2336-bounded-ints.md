### Changed

- **MCP bounded integer arguments state and declare their range once.** List limits, look-back windows and the validation wait each typed their default and maximum in code and again in served prose, and most schemas declared no range. One `MCPBoundedInt` now holds the default and the maximum, renders the property with `minimum` and `maximum`, and resolves the input. `query_logs` refuses an unknown `minLevel` and names the legal levels; before, `"warn"` returned every entry unfiltered. `set_time_limit` states its range from the shared constant. (#2336)
