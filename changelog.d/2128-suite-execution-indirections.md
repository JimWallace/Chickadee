### Changed

- **Two trivial indirections in `SuiteExecution.swift` are gone (#2128).** `outcomeTestName(for:)` only called `runnerOutcomeTestName`, and the public `runnerScriptStem` only called a private `scriptStem`. The two call sites call `runnerOutcomeTestName` directly, and `runnerScriptStem` holds the body.
