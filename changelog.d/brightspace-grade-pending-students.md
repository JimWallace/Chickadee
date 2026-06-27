### Added

- **Grade pending students and push to BrightSpace.** Instructors can now
  register a pending (pre-enrolled, never-logged-in) student into a real
  account from the **Students** tab — supplying their SSO identity — so they
  appear on assignment rosters and can be assigned a grade override. The real
  student's first SSO login adopts that account (by `externalSubject`, or by
  username when no subject was supplied), so no duplicate account is created.

### Fixed

- **BrightSpace grade sync now pushes override-only grades.** An instructor
  grade override on a student with no submissions previously stored and
  displayed the grade but never reached BrightSpace, because the sync sweep
  was driven solely by submission result rows. The override row now carries its
  own pending flag and the sweep pushes it (`override% × suite total points`).
  The manual **Push all** / **Retry failed** buttons cover these override-only
  grades too. Clearing an override on a no-submission student leaves the
  already-pushed grade as-is.
