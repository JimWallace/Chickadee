### Fixed

- **A failed assignment clone no longer leaves a setup row.** The web clone route (`POST /instructor/:assignmentID/clone`) now runs the clone in one database transaction, as the course clone does. A clone that failed after it saved the new `test_setups` row used to remove the copied files but keep the row with no zip (#3214).
