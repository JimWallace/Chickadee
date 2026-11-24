### Changed

- **Core symbols that no other module uses are now internal (#3234).** `AvatarCrestShape`, `DatasetSeedDerivation`, `JSONReindenter`, `ZipArchiverError`, `listZipContents(zipPath:)` and `runZipProcessExpectingSuccess` lose their `public` keyword. The tests that use them now import Core with `@testable`. Behaviour does not change.
