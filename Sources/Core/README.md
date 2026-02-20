# Core

Shared models and types. No Vapor dependency. Both `chickadee-server` and `chickadee-runner` depend on this target.

**Rule:** all types must be `Codable`, `Sendable`, and import no Vapor symbols.

---

## Types

### `TestStatus`

The exhaustive set of states a single test case can be in. "Could not run" is not a valid state — build failures are represented at the collection level.

| Case | Meaning |
|------|---------|
| `pass` | Test ran and all assertions passed |
| `fail` | Test ran and an assertion failed |
| `error` | Test ran but threw an unexpected exception or crash |
| `timeout` | Test exceeded the time limit |

### `TestTier`

Controls visibility of test results to students.

| Case | Raw value | Shown to student |
|------|-----------|-----------------|
| `pub` | `"public"` | Immediately after submission |
| `release` | `"release"` | Hidden until deadline; unlocked on demand |
| `secret` | `"secret"` | Never shown |
| `student` | `"student"` | Student-written tests, always visible |

The case is named `pub` (not `public`) because `public` is a Swift keyword. The JSON encoding uses `"public"`.

### `TestOutcome`

The complete record for a single test case execution.

| Field | Type | Notes |
|-------|------|-------|
| `testName` | `String` | e.g. `"testBitCount"` |
| `testClass` | `String?` | Always `nil` for shell-script runners |
| `tier` | `TestTier` | |
| `status` | `TestStatus` | |
| `shortResult` | `String` | One-line human-readable summary |
| `longResult` | `String?` | Full output, stack trace, diff, etc. |
| `executionTimeMs` | `Int` | |
| `memoryUsageBytes` | `Int?` | Gamification — `nil` until measured |
| `attemptNumber` | `Int` | Which attempt this was (1-based) |
| `isFirstPassSuccess` | `Bool` | `true` if passed on the very first attempt |

### `BuildStatus`

Collection-level build result.

| Case | Meaning |
|------|---------|
| `passed` | Build succeeded; `outcomes` is populated |
| `failed` | Build failed; `outcomes` is empty |
| `skipped` | No build step (e.g. download-only dev mode) |

### `TestOutcomeCollection`

The complete result for one submission run, reported by the worker and stored by the server.

| Field | Type | Notes |
|-------|------|-------|
| `submissionID` | `String` | |
| `testSetupID` | `String` | |
| `attemptNumber` | `Int` | |
| `buildStatus` | `BuildStatus` | |
| `compilerOutput` | `String?` | `nil` if build passed |
| `outcomes` | `[TestOutcome]` | Empty if build failed |
| `totalTests` | `Int` | Derived aggregate |
| `passCount` | `Int` | |
| `failCount` | `Int` | |
| `errorCount` | `Int` | |
| `timeoutCount` | `Int` | |
| `executionTimeMs` | `Int` | Wall time for the full run |
| `runnerVersion` | `String` | e.g. `"shell-runner/1.0"` |
| `timestamp` | `Date` | |

### `TestProperties`

Decoded from `test.properties.json` inside the instructor-uploaded test-setup zip.

| Field | Type | Notes |
|-------|------|-------|
| `schemaVersion` | `Int` | Currently `1` |
| `requiredFiles` | `[String]` | Filenames that must exist in the submission |
| `testSuites` | `[TestSuiteEntry]` | Ordered list of scripts to run |
| `timeLimitSeconds` | `Int` | Per-script timeout |
| `makefile` | `MakefileConfig?` | `nil` if no build step |

**`TestSuiteEntry`** — `{ tier, script }` where `script` is a filename at the root of the test-setup zip.

**`MakefileConfig`** — `{ target? }`. `nil` target means bare `make`; a non-nil target means `make <target>`.

### `Job`

Returned by `POST /api/v1/worker/request`. Carries everything a worker needs to run a submission without additional round-trips.

| Field | Type | Notes |
|-------|------|-------|
| `submissionID` | `String` | |
| `testSetupID` | `String` | |
| `attemptNumber` | `Int` | |
| `submissionURL` | `URL` | Worker GETs this to download the submission zip |
| `testSetupURL` | `URL` | Worker GETs this to download the test-setup zip |
| `manifest` | `TestProperties` | Parsed manifest — avoids a second round-trip |
