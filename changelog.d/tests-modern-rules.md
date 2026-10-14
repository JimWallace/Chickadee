### Changed

- **The tests follow the same Swift rules as the sources.** `Tests/.swift-format`
  is removed, so the full swift-format rule set applies to tests. SwiftLint's
  modern-idiom rules and the legacy-API rules (`NSRegularExpression`, `NSString`
  paths, `Task.sleep(nanoseconds:)`) apply to `Tests/`, and the test targets use
  `ExistentialAny` and `MemberImportVisibility`. `prefer_key_path` stays off for
  tests: the Swift Testing macros cannot expand a key path passed to a
  rethrowing function, so a closure stays inside `#expect` and `#require`.
