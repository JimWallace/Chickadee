### Fixed

- **The AGS failure-reason backfill matches the sentence its rows were written with.** `AddLTIGradeSyncFailureReasonColumn` keyed its `UPDATE` on the live `LTIGradeSyncSweep.notLaunchedMessage`, so rewording that sentence before a database applied the migration would have backfilled nothing. The matched sentence is frozen in the migration (#1811).
