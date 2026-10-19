### Changed

- **Typed reads of notebook headers.** A new `Core` type, `NotebookHeader`,
  reads the kernel names and the `nbformat` key from a notebook with
  `JSONDecoder`. It replaces `JSONSerialization` and `as?` casts at four
  sniff sites: the language derivation at upload, the notebook-functions scan,
  the worker's submission language sniff and the raw-submission extension
  guess. The personalization result parse and the runner log capture also
  decode typed values now. The notebook save guard stays on
  `JSONSerialization`, because it must reject invalid JSON. The sniffs differ
  from before in three edge cases: invalid JSON in a part that is not read no
  longer stops the sniff, UTF-32 input with a byte-order mark is not read, and
  the first of two duplicate keys wins.
