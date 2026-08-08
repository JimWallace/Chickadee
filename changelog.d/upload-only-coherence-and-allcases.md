### Fixed

- **An upload-only language can no longer be authored into notebook mode.** The
  rule "a language with no editor kernel must be `submissionMode: uploadOnly`"
  was enforced at five places and spelled `== .cpp` at three of them, so a Racket
  assignment could be flipped back to the notebook workflow from the MCP tool,
  the web editor, or a zip-borne manifest. All five now ask
  `EditorSupport`, and the refusal message names the language it refused instead
  of always saying "C++".
- **`TestProperties.effectiveSubmissionMode`** pins a kernel-less language to
  upload mode at every consumption site, the way `effectiveGradingMode` already
  did for `upload + browser`. A stored incoherent pair — from a hand-crafted zip,
  an imported course bundle, or a row written before the language existed — is
  now inert rather than a promise of an editor that cannot load.
- **Every language's runtime helper is installed, discovered from
  `allCases`.** The runner installed them through five hand-written calls under a
  comment reading "one per language", which stopped being true at the sixth:
  `test_runtime.rkt` had no embed and no write call, so a generated Racket test's
  `(require "test_runtime.rkt")` found nothing. Adding a language now fails to
  compile until it answers `runtimeHelperFiles(for:)`.

### Changed

- **Three drift guards walk `allCases` instead of naming languages.**
  `RuntimeSourceDriftTests` was five hand-written cases and now checks every
  language both ways — embed matches canonical, and no canonical helper goes
  uninstalled. The script-dispatch fixture gained Lua, Octave and C++ rows (it
  had covered neither Lua nor Octave since they shipped) plus an `allCases`
  assertion that every language's generated extension has one, with Racket
  carried as a named exemption until its dispatch lands.
  `AssignmentLanguage.lineCommentLeader` is hoisted out of `renderInputsFile` so
  the drift guard reads the same per-language fact rather than keeping a second
  copy.
