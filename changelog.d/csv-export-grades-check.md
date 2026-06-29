### Testing

- **Grade override CSV coverage.** Added a test verifying that a per-student grade override exports correctly to the grades CSV even when the student has no submission — confirming the override-without-submission path writes the correct points rather than leaving the cell blank.
