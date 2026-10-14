### Changed

- **Sources/ uses Swift APIs where Foundation's older ones were.**
  `NSRegularExpression` became regex literals and `Regex`. `NSString` path
  calls became `FilePath` calls, with the new `FilePath.removingExtension`.
  `Task.sleep(nanoseconds:)` became `Task.sleep(for:)`. SwiftLint now fails on
  each of them in `Sources/`: `legacy_objc_type` (with `NSNumber` allowed for
  `FileManager` attributes) and two custom rules.

### Fixed

- **`FilenameSafety.bareFilename` refuses `/`.** The old `NSString` call
  returned `/` as its own last component, so the check accepted it as a bare
  filename.
- **No `NSString.deletingLastPathComponent` in the worker.** On Linux it
  traps on a one-character path. `SubmissionNormalizer` called it on a
  relative path.
