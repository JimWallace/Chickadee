### Changed

- **Typed, faster reads of notebook cells.** A new `Core` type,
  `NotebookCellView`, reads each cell's type, source, id and tags with
  `JSONDecoder` and skips the rest, most of all the outputs. The reflection
  cells, the definition and function scans, the solution extractor and the
  notebook guide use it in place of `[[String: Any]]` from
  `JSONSerialization`. On a 2.8 MB notebook the read takes 0.07 s, where it
  took 0.25 s. It is a read, not a validity check: invalid JSON in a part
  that is not read no longer stops it. As with `NotebookHeader`, UTF-32 input
  with a byte-order mark is not read, and the first of two duplicate keys
  wins.
