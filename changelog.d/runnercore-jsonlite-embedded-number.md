### Fixed

- **RunnerCore JSON parser is now Embedded-Swift safe.** Its hand-rolled JSON
  number parser used `Double(String)`, which lowers to
  `_swift_stdlib_strtod_clocale` — a symbol the Embedded Swift wasm runtime does
  not provide. It linked only because the path was dead code in the browser
  build; the moment the shared `executeSuites` loop reaches it (output
  interpretation), the wasm build fails to link. Replaced with a small,
  dependency-free literal parser (no `strtod`, no `pow`/libm), shared by the
  native and embedded builds. Behaviour is unchanged for output interpretation
  (the parsed `score` is reserved and unread); pinned by new tests across many
  numeric forms.
