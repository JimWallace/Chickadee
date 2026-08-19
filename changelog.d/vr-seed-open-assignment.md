### Fixed

- **The visual-regression fixture now publishes and opens its assignment, so
  the student dashboard is captured populated.** The seed uploaded a test setup
  but never published it, and students cannot see an unpublished assignment —
  so `student-dashboard` baselined only "No assignments available yet." The
  populated assignment table had no pixel coverage on any page in either
  scheme: the `tier-open` / `tier-closed` / `tier-extended` / `tier-preview`
  status chips, achievement badges and their `+N` overflow chip, the grade
  override tag, the submission-history cell, and the icon-button action row
  were all invisible to the harness — the same class of regression the
  dark-mode banner bugs in #1133 were, which is what the harness exists to
  catch. Opening needs no runner: quick-publish leaves `validationStatus` nil
  and `applyVisibility` admits nil. The axe-core scan covers that markup for
  the first time too, since it shares the fixture.
