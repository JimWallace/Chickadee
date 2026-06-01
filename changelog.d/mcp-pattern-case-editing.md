### Added

- **MCP personalization tools — pattern-family case editing.** `update_pattern_family`
  can now edit a generated case's test logic — its `args` and `expected` (plus the
  parallel `argVarRefs` / `argsProvided`) — not just the family defaults and which
  cases are enabled. Edits re-save through the same `applySuiteEdit` →
  `applyPatternFamilies` path the web editor uses, so the structural and per-kind
  validation (arg count vs. parameters, the kind-specific `expected` shape, `$var`
  resolution) runs synchronously and rejects bad edits at call time. Values are
  sent as raw JSON, so types stay faithful (no client-side coercion).
