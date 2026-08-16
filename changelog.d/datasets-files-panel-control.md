### Added

- **Per-student datasets are markable from the Files panel.** Each support-file
  row on the assignment create and edit pages now carries a "Per-student sample"
  toggle and a row count, saved in place with no page reload. Marking a dataset
  had shipped as `PUT /instructor/:id/datasets` and the `set_dataset` MCP tool
  only, so an instructor without an agent had no way to do it at all. The
  create page gets the same control against a new draft-scoped
  `GET`/`PUT /instructor/new/draft/datasets`, which shares the published pair's
  validation, and both pages read their marks from the one lookup
  `get_support_files` reports from — so the web UI and the agent surface cannot
  disagree about a file. A `datasets` array naming the same file twice is now
  rejected by either endpoint rather than leaving which spec wins to whichever
  consumer folds the array.
