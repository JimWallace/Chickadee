### Changed

- **The personalization driver derives each language's support-file extension
  from its descriptor** instead of re-listing it. Five arms of
  `supportFileEntries` filtered on a hard-coded `"r"` / `"rkt"` / `"lua"` /
  `"m"` / `"java"`, each duplicating `LanguageDescriptor.sourceFileExtension`.
  They agreed, but nothing made them keep agreeing: a drifted extension would
  have silently found no support files, so an `=` expression calling a helper
  the instructor did ship would fail as an undefined function.
