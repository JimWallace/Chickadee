### Changed

- **`OperationalDiagnosticsService` is checked by the compiler.** Its four stored properties are constants (three actors and a `Sendable` struct), so it no longer needs `@unchecked Sendable` (#1927).
