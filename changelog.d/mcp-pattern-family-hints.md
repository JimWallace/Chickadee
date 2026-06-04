### Added

- **MCP pattern families can now set instructor hints.** `create_pattern_family`
  and `update_pattern_family` accept a family-wide `defaultHint` and a per-case
  `hint` (per-case overrides the family default; on update an empty string clears
  a hint and nil leaves it untouched). The hint surfaces to the student as a
  "💡 Hint" only on a failing case via the existing display-time
  `resolvedHint(defaults:)` join — nothing is baked into the generated script.
  `get_suite` already returns these in the `family` spec. Previously the fields
  were manifest-authorable (since v0.4.94) but had no agent surface, so hints
  authored through MCP were silently dropped.
