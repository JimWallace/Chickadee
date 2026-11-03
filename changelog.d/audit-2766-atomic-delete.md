### Fixed

- **Assignment delete and course purge are atomic (#2766).** Deleting an assignment now removes all its rows in one transaction. A database error midway no longer leaves a live assignment whose submissions have no results. Both the assignment delete and the course purge now remove files only after the transaction commits, so a rollback no longer leaves rows that name deleted files. The assignment delete audit entry is now written after the commit, so a rolled-back delete leaves no false entry.
