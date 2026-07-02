### Changed

- **`submissionPage` fetches the test setup once (#1128).** The student
  result page's helpers — manifest display data, class-goal bonus,
  individual-badge evaluation, built-in badges, class-goal views — each
  re-fetched the same `APITestSetup` row and re-decoded its manifest
  (~4–5 fetches per render of the hottest student-facing page). The handler
  now loads `(setup, props)` once and passes them down; `classGoalBonusPoints`,
  `suiteTotalPoints`, `earnedIndividualBadges`, and `loadClassGoalViews` take
  the decoded manifest, and the BrightSpace grade selection shares one fetch
  between its denominator and bonus reads. No behavior change.
