### Fixed

- **A data export requested during shutdown no longer outlives the drain.** `DataExportManager` started new work while it was draining, so that work could read the database after Fluent closed it. It now refuses new work once the drain begins, as `BackgroundWork` does. The export row stays `pending`, and the reaper marks it failed. (#2302)
