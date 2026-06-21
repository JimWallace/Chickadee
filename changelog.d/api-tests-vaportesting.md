### Fixed

- **api-tests flakiness: migrated the HTTP-test surface off XCTVapor to Vapor's
  Swift-Testing-native `VaporTesting`.** The `APITests` target drove requests
  through XCTVapor (`app.testable().test(...)`), which reports a thrown
  request/decoding error via `XCTFail`. Called from a Swift Testing `@Test`,
  `XCTFail` is mis-attributed and intermittently dropped — surfacing as
  unattributed "issues" and the "test failures not being reported" CI warning.
  All 102 `APITests` files now `import VaporTesting` and use `app.testing()`,
  so request-execution failures are recorded with `Issue.record(sourceLocation:)`
  and attributed to the right test. The central `Application.asyncTest` /
  `asyncSendRequest` helpers thread the new `fileID`/`filePath`/`line`/`column`
  source location through. Incidental XCTest assertions in the migrated files
  (`XCTFail`, `XCTAssert{Greater,Less}Than*`, `XCTSkip`) were converted to
  `Issue.record` / `#expect` / `IssueRecorded`. `scripts/no-new-xctest.sh` now
  also blocks `import XCTVapor` so the flaky bridge can't return. No production
  code changed.
