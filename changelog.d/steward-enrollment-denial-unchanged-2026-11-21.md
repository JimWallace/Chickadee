### Changed

- **Enrollment contract checks that a refusal changes nothing.** The MCP enrollment-denial contract now compares every row of the target course before and after each refused call, so three per-tool copies of that check are gone.
