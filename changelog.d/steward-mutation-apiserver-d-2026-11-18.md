### Changed

- **Database-free tests for the live board ETag, from a mutation run on five more APIServer helpers.** A steward mutation run on `DeployMode`, `DeployReleaseNotes`, `RunnerVersionReport`, `TierFilter` and `LiveBoardETag` in `Sources/APIServer/Utilities` found no survivor in the first four. `LiveBoardETag` had only tests that need a database, so a new suite, `LiveBoardETagTests`, checks the tag without one. Its one survivor, the staff-or-student word swapped, cannot change any tag comparison, and `Tools/mutation/equivalent-mutants.json` records why. No product code changes.
