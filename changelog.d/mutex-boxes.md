### Changed

- **Three lock boxes moved to `Mutex`.** `AssignmentVersionCaptureScope`, `AdminEventSink` and `MCPVersionCaptureScope` each guarded one value with an `NSLock` behind `@unchecked Sendable`. They now hold a `Synchronization.Mutex`, which the compiler checks, and the unchecked conformances and the lock/unlock pairs are gone. No behaviour change (#1656).
