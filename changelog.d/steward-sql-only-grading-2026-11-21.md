### Removed

- **Non-SQL fallbacks in grading.** The Swift fallbacks for a database without SQL are gone from the runner pending-work probe and pending count, the validation variant write, the submission status read, the best-grade reads and the BrightSpace pending flag of a grade override. They now throw.
