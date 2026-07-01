### Testing

- Added regression tests for the student "deny" surface (#417): a non-staff
  student listing `GET /api/v1/submissions` is scoped to their own submissions
  and never sees another student's (with and without a `testSetupID` filter),
  and a per-course student is refused the instructor area entirely (assignment
  content edit and retest both 403). Closes the two coverage gaps a test audit
  flagged; no behaviour change.
