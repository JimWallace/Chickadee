### Fixed

- **The package builds on macOS again.** CI runs only on Linux, so code that
  compiled only there had piled up: `FilePath` from `SystemPackage` passed to
  Subprocess (which takes `System.FilePath` on Darwin), Glibc-only imports and
  `sigaction` fields, `FileManager` captured in `@Sendable` closures, and
  directory enumerators iterated in `async` code. Xcode 27.2's SDK also marks
  `String(format:)` `@unsafe`, which strict memory safety turns into an error;
  every call now goes through `String(cFormat:)` in Core, which marks it
  `unsafe` only on Darwin and formats exactly as before. The macOS deployment
  floor moves from 26.2 to 27.0 for `withTaskCancellationShield`. Linux is
  unchanged.
