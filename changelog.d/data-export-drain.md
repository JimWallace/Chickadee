### Fixed

- **Data export generation no longer outlives the server.** `DataExportManager` now owns each generation task and drains them at shutdown, before Fluent closes the database. A bare `Task {}` used to keep running through `asyncShutdown` and trap in `FluentProvider` on a cleared `app.db` (#1700). A cancelled generation is logged, not marked failed.
