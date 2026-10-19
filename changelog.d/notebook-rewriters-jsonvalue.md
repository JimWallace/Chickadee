### Changed

- **The notebook rewriters write sorted, deterministic JSON.**
  `normalizeNotebookForJupyterLite`, `mergeNotebook`, `filterNotebook`,
  `NotebookSubstitution.apply`, `PersonalizedCellRestoration` and the class
  corpus now parse a notebook as `JSONValue` and write it with sorted keys
  (`JSONValue.data(fromObject:)`). The same notebook now always gives the
  same bytes, so a save with no edit keeps its version hash. The first save
  of each stored notebook after this release writes its keys in a new order
  one time, which adds one version entry per assignment. The parse and encode
  together take about the same time as before. `NotebookCellSources` now
  returns `[String: JSONValue]` cells, and its `[String: Any]` form is
  removed. The validity gates stay on `JSONSerialization`. Some edge cases
  differ in the rewritten bytes:
  - A JSON number that a `Double` or an `Int` cannot hold exactly is rounded:
    an integer beyond the 64-bit range becomes a double, a decimal with more
    than about 17 significant digits is rounded, and `-0.0` becomes `0`.
    Source cells are strings and are not affected; only numbers in output
    data or metadata are.
  - UTF-32 input with a byte-order mark is not read, so the rewriter leaves
    it unchanged (and substitution refuses it).
  - When a key appears twice, the first value wins.
- **The submission diff reads more notebooks.** It reads cells with
  `NotebookCellView`, so a notebook with invalid JSON in an output now shows
  its diff, where the page said that it could not be parsed.
