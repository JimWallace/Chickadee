### Fixed

- **The AGS retry-on-launch rule keys on a reason code, not the sentence.** `lti_grade_syncs` gains a `failure_reason` column beside the instructor-facing sentence; the sweep writes both, the launch retries only rows whose code is `notLaunched`, and the migration backfills the code on rows that failed before. Rewording a message no longer changes behaviour (#1652).
