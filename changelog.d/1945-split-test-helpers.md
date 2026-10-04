### Changed

- **The APITests helper file is now eight files, one job each (#1945).**
  `Tests/APITests/TestHelpers.swift` had 1,717 lines and six unrelated jobs.
  The code moves without change to `TestDatabase.swift`,
  `MigratedSQLiteTemplate.swift`, `MigratedPostgresSchemaPool.swift`,
  `SchemaMutatingSuites.swift`, `TestApp.swift`, `TestRequests.swift`,
  `TestLogin.swift` and `WorkerHMACTestHeaders.swift`. Two functions lose
  `private` so that the next file can call them. The comment on
  `SchemaMutatingSuites` now names all five suites. No test body changes.
