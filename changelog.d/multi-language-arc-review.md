### Fixed

- **A `family:<id>` dependency broke the save on every language but Python.**
  `buildConfiguredSuiteEntries` computed the filenames a family dependency token
  expands to without passing the assignment's language, taking the `.python`
  default, while the suite entries beside them were rendered with it. On an R,
  Lua, Octave, C++ or Racket assignment the expansion named `.py` files that do
  not exist, and the manifest's own dependency validation rejected the save with
  a 422. The filenames are now read off the rendered scripts, so there is no
  second computation left to disagree with the first.
- **The pattern-family filename-collision check was inert in five of six
  languages.** It compared a family's Python filenames against a suite of `.R` /
  `.lua` / `.m` / `.sh` / `.rkt` scripts, so it could never collide. It now asks
  across every language, matching the notebook-check collision test beside it.

### Changed

- **Language resolution is up to 426× faster.** Resolving a 40-entry plain `.sh`
  suite — the system's original mode, and a supported one — cost 1.27 ms on the
  worker claim path and every instructor page render, because the walk called
  `URL(fileURLWithPath:).pathExtension` (4.5 µs per call, measured) once per
  suite entry per language and rebuilt a `LanguageDescriptor` literal on every
  fact it read. Descriptors are stored, extensions resolve through a map derived
  from `allCases`, and the suite is walked once. Same answers, including the
  `allCases`-order tie-break, now pinned by a test.
- **Octave's line-comment marker is `%` everywhere.** It was the one fact with
  two answers in the tree — `LanguageDescriptor.lineCommentPrefix` said `#` and
  `AssignmentLanguage.lineCommentLeader` said `%`. Both parse in Octave, which
  is why they disagreed for four releases without failing. The inlined-inputs
  banner and the starter-notebook scaffold move to `%`; an existing `#` banner
  is still recognised and stripped.

### Removed

- **`AssignmentLanguage.lineCommentLeader`**, the second copy of the above.
- **`AssignmentLanguage.isRNotebookMetadata` / `isRNotebook`**, dead since the
  callers their doc comment named moved to the general `fromNotebookMetadata`.
  A `Bool` return is the `isRNotebook(nb) ? .r : .python` shape that type-checks
  forever and routes every other language to Python.
- **The hand-written `pythonKernelNames` copy in `NotebookContentHelpers`**, now
  read off the descriptor like every other language's aliases.
