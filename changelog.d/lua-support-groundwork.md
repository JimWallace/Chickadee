### Fixed

- **The Lua interpreter is now on the runner image.** `.lua` scripts classify to
  an `env lua` subprocess, but the image installed only `python3` and `r-base`,
  so native grading failed with command-not-found — and because instructor
  validation is enqueued as a `kind == .validation` submission graded by the
  *native* worker, even a purely browser-graded Lua assignment could not be
  validated. The browser→worker failover was a dead end for Lua for the same
  reason.

### Added

- **`JSONValue.luaLiteral` and `extractLua`**, the two pieces of Lua's
  authoring support that can be written and proven in isolation. The literal
  renderer's interesting case is `null`: a bare `nil` inside a Lua table
  constructor is not stored, so `{60, nil, 20}` makes `ipairs` visit one
  element instead of three and `table.concat` raise. A `chickadee.NULL`
  sentinel (now defined by `test_runtime.lua`, and compared by identity in
  `chickadee.equal`) occupies the slot instead — Lua's answer to the problem R
  solves with `NA`. Every expectation is checked against a real `lua 5.4`.
  `extractLua` shares R's implementation via `extractWithCellMarkers`, differing
  only in the comment marker.

### Changed

- **The notebook-language sniff is a table rather than an R special case.**
  `AssignmentLanguage.notebookKernelNames` plus `fromNotebookMetadata` replace
  the hand-inlined `rKernelNames` checks; `isRNotebookMetadata` is now a thin
  equality over the one implementation, and graded-script resolution asks for
  "any non-default language" rather than "is it R". Behaviour is unchanged —
  Python stays the fallback and is deliberately given no positive alias set.

- **`docs/adding-a-xeus-kernel.md` now carries the second half as a
  compiler-generated worklist and a done test.** Adding `case lua` to
  `AssignmentLanguage` and rebuilding enumerates the work in three passes — 10
  sites in Core, 3 in RunnerCore/Worker, 12 in APIServer — and the document
  records all 25, plus the four the compiler *cannot* see (the runner image,
  `shouldNormalizePythonSubmission`, the generated JS constants, the vendored
  browser wasm), each of which has shipped broken at least once. It also states
  the rule the Lua work surfaced: a vendored kernel is registered in the editor,
  so there is no such thing as a grading-only kernel — finish the second half or
  do not vendor it.
