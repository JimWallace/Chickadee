### Changed

- **Typed reads of notebook headers.** A new `Core` type, `NotebookHeader`,
  reads the kernel names, the `nbformat` key and the cell count from a
  notebook with `JSONDecoder`. It replaces `JSONSerialization` and `as?` casts
  at five read sites. The personalization result parse and the runner log
  capture also decode typed values now. The behaviour does not change, except
  that a UTF-32 notebook is no longer read.
