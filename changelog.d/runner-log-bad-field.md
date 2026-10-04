### Fixed

- **A runner log value that JSON cannot hold no longer erases the line.** `writeStructuredRunnerLog` fell back to only the event name and timestamp when one field was a `Date`, a `URL`, an enum or `NaN`. Such a value is now written as its description, and the other fields stay. No call passes such a value today; this removes the trap (#1932).
