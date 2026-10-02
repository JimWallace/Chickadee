### Fixed

- **Un-archiving a course checks the per-term duplicate rule first.** The toggle saved straight into the unique index over active courses, which rejected the save as an unhandled error once an active course held the same code and term. It now reports the duplicate the way the edit form does (#1777).
