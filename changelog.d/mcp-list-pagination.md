### Added

- **MCP list pagination.** `tools/list` and `resources/list` now honor the
  spec's cursor-based pagination: results carry a `nextCursor` when more pages
  remain (page size 100), and an unparseable `cursor` is rejected with
  `-32602` instead of being silently ignored. Today's 34-tool catalog still
  fits one page; the resource listing (one entry per accessible assignment)
  is what this protects on large deployments.
