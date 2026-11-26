### Changed

- **Test that the staff Recompute counts assignment badges.** `CourseAchievementsTests` now calls the roster evaluator that the staff Recompute uses, for a course achievement that needs one assignment badge. It checks that the evaluator grants nothing before the student has the badge and grants the course achievement after.
