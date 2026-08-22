### Added

- **Every student has a chickadee and a per-course name.** The account page
  shows a generated avatar in place of the initials monogram, and names the
  pseudonym the student appears under in each of their courses. Both are drawn
  on first view and stored — `users.avatar_spec` and
  `course_enrollments.avatar_handle`, the latter unique within a course — so
  neither changes between page loads. Handles come from two curated word lists
  (6,400 pairs) drawn without replacement per course. Both appear in the
  personal-data export.

### Changed

- **The account page's initials monogram is retired.** `accountMonogram`, the
  `.account-monogram` rule and its component-vocabulary entry are gone; the
  identity circle is the student's bird.
- **`check-styles.sh` admits the avatar custom properties inline.** The seven
  `--av-*` names join `--bar-h` on the per-datum allowlist, for the same reason
  the rule already states: each carries a value that varies per student, which
  no stylesheet can hold.
