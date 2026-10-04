### Changed

- **Four silent test skips are now traits (#1947).** Four tests returned
  early, with no report, when `python3` or the vendored editor was absent.
  They now carry `.requiresPython3` or a trait for the vendored editor, so a
  skip shows in the report and fails CI. A guard in `LuaStdoutCaptureTests`
  that the trait already made unreachable is gone. The python3 guard in the
  pattern-family syntax helper stays, and its comment now says why a trait
  cannot replace it.
