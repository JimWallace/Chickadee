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

  It also records **what a half-supported language actually does**, measured
  rather than predicted, since Lua spent a release in exactly that state: the
  worker path fails with exit 127 (`env: 'lua': No such file or directory`),
  which RunnerCore maps to `error` rather than `fail`, and instructor
  validation — a native-worker job even for browser-graded assignments — hits it
  before any student can. The section also flags the trap that follows: putting
  the interpreter on the image removes that loud signal while leaving four
  silent ones (empty `_ck_inputs`, `.py` pattern cases in a Lua assignment,
  likewise notebook checks, and Lua notebooks extracted through the Python
  sanitizer), so the interpreter fix is only safe as part of finishing the
  second half.

- **A language conformance matrix** (`Tests/APITests/LanguageConformanceMatrixTests`)
  — what "supported" *means*, asserted for every `AssignmentLanguage` rather
  than for whichever ones someone remembered. Before it, the suite had exactly
  one test parameterised over language and it read
  `arguments: [AssignmentLanguage.python, .r]` — a hand-listed pair, not
  `allCases`, so a third case would have left it silently testing two languages
  and passing. That is the same fail-open shape as the `chickadee-*` glob and
  `expected_language`; this was the third instance and the worst-placed, since
  it is the thing meant to notice omissions.

  Everything in the matrix iterates `allCases`, and the per-language glue it
  needs itself lives in one exhaustive `adapter(for:)` switch, so a new case
  cannot compile without supplying it. It covers structural invariants
  (extensions and kernel aliases disjoint, inputs filename consistent with the
  language, kernel env file exists), **the interpreter being present on the
  runner image** (the exit-127 defect), every `PatternKind` and
  `NotebookCheckKind` rendering per language with unsupported kinds *named*
  rather than merely absent, every generated script **parsing in its own
  language**, and the inputs file the server writes being the one the language
  actually reads back. `PatternKind` gained `CaseIterable` to make the kind half
  possible — it had none, so the kinds could not be iterated at all.
