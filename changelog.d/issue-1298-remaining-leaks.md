### Fixed

- **The test suite no longer leaks the ~1 GB per run that remained after
  #1299 (#1298).** Both residual causes are closed. `withApp` — the teardown
  route nearly every suite uses — now performs the full `tearDownTestApp`
  instead of a bare shutdown, so per-app temp directory trees are removed
  (~45 MB / ~1,400 entries per run). And teardown now discovers, via
  `PRAGMA database_list`, the real temp file sqlite-kit secretly backs every
  "in-memory" test database with — upstream never deletes it — and removes it
  (~973 MB / ~1,566 entries per run). Regression tests pin both outcomes,
  including a loud failure if sqlite-kit's temp-file scheme ever changes out
  from under the discovery.
