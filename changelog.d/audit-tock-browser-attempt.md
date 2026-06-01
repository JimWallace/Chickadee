### Fixed

- **Browser-graded results now record the true attempt number.** The browser
  runner builds its result before it knows the server-side attempt number, so it
  always stamped `attemptNumber: 1` (and therefore `isFirstPassSuccess` for every
  pass). The server now reconciles the stored collection — submission ID, attempt
  number, and each outcome's `isFirstPassSuccess` — against the value it derived
  for the submission, so the First-Try-Perfect badge and per-attempt analytics
  are correct for browser-graded assignments.
