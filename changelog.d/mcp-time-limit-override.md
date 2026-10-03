### Changed

- **Every MCP time-limit override field states its bounds.** The seven `timeLimitSeconds` and `defaultTimeLimitSeconds` schema properties now carry `minimum: 0` and `maximum: 600`, taken from the one range constant, and no description types the range by hand. The five tools that take an override parse it with one function, `parseTimeLimitOverride`, where omitted leaves it unchanged, 0 clears it, and any other value must be in range (#1941).
