### Changed

- **Typed throws in Core and the runner.** Functions whose set of errors is closed now declare it: the runner's notebook validation and extraction, MIME detection, disk-space and `make` checks, and result and heartbeat reporting; in Core, avatar customization and the v2 manifest checks. `executeTestSuites` throws nothing, so it no longer says `throws`. The rest stay untyped, because Foundation, Subprocess or network errors pass through them, or they are `Codable` requirements.
