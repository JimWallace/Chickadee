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
  removed. The validity gates stay on `JSONSerialization`. Two edge cases
  differ: UTF-32 input with a byte-order mark is not read, and the first of
  two duplicate keys wins.
