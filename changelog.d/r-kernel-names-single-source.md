### Changed

- **One source of truth for R-notebook kernel detection.** The R kernelspec
  alias list (`ir`, `r`, `webr`, `xr`) was hand-inlined at five sites across two
  languages, so teaching Chickadee a new R kernel meant finding all five and
  missing one would silently grade an R submission as Python. Detection now
  lives in `AssignmentLanguage.isRNotebookMetadata(_:)` / `isRNotebook(_:)`
  (Core), and every Swift caller routes through it: `AssignmentLanguage.rederive`,
  the worker's submission routing (`submissionIsRNotebook`) and notebook→source
  extraction (`extractNotebooksToCode`), assignment requirement scanning, and
  JupyterLite kernelspec normalization. `extractNotebooksToCode`'s
  `forcedLanguage` is now a typed `AssignmentLanguage?` instead of a stringly
  typed `String?`. The browser runner cannot import Swift, so its copy is named
  (`R_KERNEL_NAMES` in `browser-runner.js`) and pinned to the Swift set by a new
  drift test, `Tests/BrowserRunnerJSTests/r-kernel-names-drift.test.mjs`, which
  fails the build if the two ever diverge. Behaviour is unchanged — same aliases,
  same precedence, generated script bytes untouched.
