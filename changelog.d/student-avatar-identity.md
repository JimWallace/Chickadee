### Added

- **Every student has a chickadee and a per-course handle.** The account page
  shows a generated avatar in place of the initials monogram, and names the
  handle reserved for the student in each of their courses. Both are drawn on
  first view and stored — `users.avatar_spec` and
  `course_enrollments.avatar_handle`, the latter unique within a course — so
  neither changes between page loads, and neither is derived from the student's
  identity. Handles come from two curated word lists (6,400 pairs) drawn without
  replacement per course, and are issued to student enrollments only: staff
  teaching a course appear under their own name. Both appear in the
  personal-data export. Nothing displays either to anyone else yet — they are
  stored now so they are stable when a leaderboard does.
- **The avatar has five axes: 92,160 distinct birds.** Cap (8), wing pattern
  (6, symmetrical), expression (6), accessory (8 in 5 accents) and backdrop (8).
  Body, cheek, beak and bib are fixed — they are what keeps every bird a
  chickadee even when the cap goes plum.

### Changed

- **The account page's initials monogram is retired.** `accountMonogram`, the
  `.account-monogram` rule and its component-vocabulary entry are gone; the
  identity circle is the student's bird.
- **`check-styles.sh` admits the avatar custom properties inline.** The four
  `--av-*` names join `--bar-h` on the per-datum allowlist, for the reason the
  rule already states: each carries a value that varies per student, which no
  stylesheet can hold.
