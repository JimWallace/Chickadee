### Added

- **Authorable individual badges (achievements Phase 4).** Instructors can now
  author per-student badges on the assignment edit page — a "Badges" card where
  each row is a caption, an emoji, and the condition that earns it: a score
  threshold ("Score ≥ 90% → Sharpshooter") or a specific test passing ("a secret
  test passes → Recursion Master"). Earned badges show on the student's
  submission. Cosmetic (no grade effect), evaluated per-student from their own
  result — and the evaluation reads every tier, so a badge keyed to a *secret*
  test works without revealing the test. Persisted via `PUT /instructor/:id/badges`.
