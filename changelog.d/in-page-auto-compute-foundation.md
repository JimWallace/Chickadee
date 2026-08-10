### Added

- **The in-page auto-compute worker can now be given its language's own value
  serializer and JSON escaper.** `AssignmentLanguage.autoComputeRuntimeSource`
  seeds the source a worker must prepend before it can report a value — the
  SAME constants the server driver and grading runtime already use, so the two
  substrates cannot disagree about what a value looks like. Lua and Octave need
  a serializer and an escaper; R needs only an escaper (`deparse` is a builtin);
  Python needs neither.

  The eval protocol is unchanged — the one `python-eval-worker.js` already
  speaks, with the payload printed as JSON behind a per-run nonce. An earlier
  draft of this work proposed a second, nonce-framed encoding to avoid pushing
  escapers into three languages; the escapers turned out to already exist as
  Core constants, so framing would have bought nothing and cost a second payload
  encoding and a second parser.

### Changed

- **R's char-by-char JSON string encoder moved from `PersonalizationEvaluator`
  into `RPersonalizationRuntime`**, where a second consumer can share it rather
  than copy it. Worth knowing when reaching for one: there are two R encoders in
  the tree, and this is the robust one — the `gsub`-based encoder in the grading
  runtime trips over replacement-string backslash rules, which is why this one
  was written.
