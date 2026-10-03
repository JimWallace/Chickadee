### Changed

- **One type for the latest-submission cell.** The student dashboard, the course's per-student view and the assignment roster each built the same cell (submission count, latest submission, grade) with the same rules written three times. `LatestSubmissionCell` now holds those rules, and each row nests it as `latest`. The pages render the same (#1711).
