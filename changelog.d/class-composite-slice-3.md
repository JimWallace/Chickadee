### Added

- **Class composite: slot dealing (slice 3 of `docs/class-composite.md`).** A student is dealt one slot of a class composite when they first open the assignment inside its session window, or when their first submission is graded. The slot reaches the test script as the per-student inputs `composite_slot`, `composite_col` and `composite_row` on both grading paths; a validation run and staff grading in the browser get slot 0. The composite's structure now locks at the first dealt slot as well as the first submission. A class composite needs a declared language, and runners must advertise the new `activity-composite` capability to claim its jobs.

### Fixed

- **MCP `set_activity` lock checks read the owner database pool.** The least-privilege MCP role reads `submissions` filtered to validation runs, so on its own pool the activity-kind lock saw no student submissions.
