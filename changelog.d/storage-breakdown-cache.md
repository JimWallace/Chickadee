### Changed

- **The admin storage breakdown is cached behind a single-flight TTL.**
  Building it stats every submission file ever kept plus the whole static
  asset tree, so the "are we running out of disk" page got slowest exactly
  when there was the most disk to account for — and the read-only admin
  MCP's `get_storage_usage` made it pollable. The `/admin/storage` page and
  the MCP tool now share one cached context; the walks run at most once per
  minute no matter how many pollers ask (#1382 item 5).
