### Added

- **Octave assignments compute expected values in the browser**, on the vendored
  xeus-octave kernel. That closes the set: every language with an editor kernel —
  Python, R, Lua, Octave — now computes in the page, and the two that route to
  the server are the two with no kernel to run. `OctaveAutoComputeRuntimeTests`
  pins that correspondence, so a future kernel language cannot quietly ship on
  the server driver.

  Octave costs neither of the other kernels' shape constraints — no
  inter-expression yield, no `return <cell>` mis-read, and its cells share one
  base workspace — so its snippets are plain statement lists. Its one shape
  requirement is the `1;` guard on the boot cell, without which the cell reads
  as a function file and the seeded runtime never registers.

- **`octaveLiteral` in `Public/octave-grading-shared.js`**, pinned to
  `JSONValue.octaveLiteral` by `Tests/Fixtures/octave-literal-contract.json`,
  which both implementations read. The trap it exists for: `[...]` in Octave
  concatenates rather than collecting, and a number beside a string is coerced
  to its character, so `[65, "bc"]` is the char array `"Abc"`. Brackets are used
  only for an all-numeric/boolean array; anything else is a cell.

- **The Octave snippets are executed under a real interpreter in CI**
  (`Tests/BrowserRunnerJSTests/octave-eval-execution.test.mjs`), against the
  runtime the server actually seeds. A browser-grading smoke row covers the
  kernel half.

### Fixed

- **A solution function sharing a builtin's name is now the one that gets
  called.** `exist("area")` reports the solution's command-line function while
  `str2func("area")` hands back Octave's *plotting* `area` — so a handle-based
  lookup would have graded against a completely different function, reporting
  "no graphics toolkits are available" as though the instructor's solution had
  raised it. Command-line functions are resolved by name. Found by executing the
  snippets rather than inspecting them.

- **`octaveStringLiteral` now escapes control characters**, matching
  `encodeOctaveString` in Swift. It passed them through, which was survivable
  while its callers were names Chickadee controls and is not once it renders
  instructor text. The escape is exactly-three-digit octal, not `\x`, because
  Octave's `\x` consumes every hex digit that follows — `"\x0abc"` would swallow
  four characters of payload.

- **The language-conformance guard no longer demands every interpreter of every
  apt-get in the workflow.** It matched any `--no-install-recommends` line,
  including a job that installs two interpreters on a plain runner for the
  eval-snippet execution suites; it now matches the probe-guarded fallback
  installs it was written for.
