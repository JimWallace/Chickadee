### Fixed

- **Dashboard and submission-page grades now agree.** The submission page used
  to headline a tier-filtered grade (e.g. 100% from public tests only before a
  deadline) while the dashboard showed the all-tier grade — two different
  numbers for the same student. Both now report the same all-tier grade, so the
  number no longer jumps when the deadline passes.

### Changed

- **Release/secret tests are presented more deliberately to students.** The
  grade is always computed over every tier (public + release + secret), so it
  is stable across the deadline. Release tests are now listed by name (with
  their instructor hint on failures) even before the deadline — only their
  detailed output is withheld until the deadline. Secret tests are never
  itemized but their aggregate pass/fail counts are shown and count toward the
  grade. First-Try Perfect now rides the all-tier grade, so it can't be earned
  while a hidden test is still failing.
