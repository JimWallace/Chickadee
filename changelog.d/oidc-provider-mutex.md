### Changed

- **The OIDC configuration provider uses `Mutex`.** It held the last `NIOLockedValueBox` in the server after #1668. It now uses `Synchronization.Mutex` like the rest of the code base, and `import NIOConcurrencyHelpers` is gone (#1928, part 1).
