### Changed

- **Sources/ uses Swift APIs where Foundation's older ones were.**
  `NSRegularExpression` became regex literals and `Regex`. `NSString` path
  calls became `FilePath` calls, and the stem of a suite file name comes from
  `runnerScriptStem`.
  `Task.sleep(nanoseconds:)` became `Task.sleep(for:)`. SwiftLint now fails on
  each of them in `Sources/`: `legacy_objc_type` (with `NSNumber` allowed for
  `FileManager` attributes) and two custom rules.
- **A `programIO` regex case is checked with Swift's regex grammar.** The
  save-time check used ICU's grammar before. Both refuse an unbalanced group;
  they differ on rare syntax. The language that runs the test still has the
  last word, as before.

### Fixed

- **`FilenameSafety.bareFilename` refuses `/`.** The old `NSString` call
  returned `/` as its own last component, so the check accepted it as a bare
  filename.
- **No `NSString.deletingLastPathComponent` in the worker.** On Linux it
  traps on a one-character path. `SubmissionNormalizer` called it on a
  relative path.
