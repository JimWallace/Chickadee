### Changed

- **Tests for the LEARN roster sweep and the BrightSpace sync bookkeeping.** New suites cover the course loop of the roster-readiness sweep (a course with no org unit, an identity that does not resolve, a classlist read that fails, the summary log line) and its monitor, and the failure paths of the grade-sync bookkeeping: a lost row save while a failure is recorded, a lost sync-log row, the "Sync now" requeue of errored overrides and removals, and the background sweep that "Sync now" starts. No product code changed.
