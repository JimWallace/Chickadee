### Fixed

- **One running tournament, one BrightSpace credential, one validation batch and one lab group set per scope, held by the database.** Each was a read-then-write that two requests at once could both pass. A migration removes any duplicates first, keeping the newest row.

### Changed

- **Fewer statements on grade pushes, coverage and the claim path.** Class coverage, grade-override flags, the LTI queue and BrightSpace requeue write in one statement instead of one per row; grade overrides set and clear in one transaction. The classmate chooser, the queue-depth timeline, the activity chart, the data export's audit filter, the metrics series and the class-goal sweep do their picking and counting in SQL. The connection-budget comments now count both servers of a blue-green deploy.
