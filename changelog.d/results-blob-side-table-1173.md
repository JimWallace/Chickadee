### Changed

- **The result collection blob moved to a side table (#1173).** Every full
  `results`-row load — the preferred-result maps behind the dashboard and
  per-student history, submission detail, sweeps, bundle export — previously
  dragged the serialized `TestOutcomeCollection` (up to the 6 MB budget per
  row) whether or not it was read, and the blob dominated the table's
  on-disk footprint. It now lives in `result_collections(result_id,
  collection_json)`: hot result rows are blob-free by construction, and the
  few readers that need the collection (result JSON endpoint past its ETag
  check, submission detail render, validation results, bundle export) fetch
  exactly the blobs they display. Writes stay atomic — the result row and
  its blob persist in one transaction, and deletes cascade. The migration
  backfills existing blobs in bounded chunks entirely inside the database,
  then drops the old column.
