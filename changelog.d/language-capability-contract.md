### Changed

- **`LanguageDescriptor` now carries two capabilities as implementations rather
  than claims.** `functionScan` holds the definition patterns a language's
  solution notebook is read with, and `autoCompute` names the in-page worker
  that computes a case's expected value (or says the server evaluates instead).
  Both were previously a boolean somewhere else with the implementation
  elsewhere again — the shape that had already drifted once, where a capability
  can be claimed and not supplied and an instructor finds out by being told
  their solution is empty. A seventh language now either supplies the patterns
  or declares `noSolutionNotebook`, and either names a worker or takes the
  server driver; there is no answer that compiles and does nothing.
  `notebookFunctionScanSupport` and `AuthoringLanguageFacts` derive from these
  rather than restating them.

- **Auto-compute routes on the descriptor, not a language name.** The editor
  read `name !== 'python'` and sent everything else to the server, which was
  the wrong rule for a surface whose job is in-browser authoring: an author
  changing a case should see what their solution returns without a round-trip.
  It now spawns whatever worker the language declares, and only falls back to
  the server for a language that declares none. R, Lua and Octave still declare
  the server driver — their kernels exist but their eval workers are not written
  yet, and declaring a worker before writing it would have the editor spawn a
  404 and auto-compute stop silently. Flipping each is one line, one worker, and
  one smoke-matrix row.
