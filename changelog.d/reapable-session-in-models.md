### Changed

- **`ReapableSession` lives in `Models/` with the other Fluent models.** It was the one model class declared inside a service file, so a reader of `Models/` could not find the `_fluent_sessions` mapping (#1735).
