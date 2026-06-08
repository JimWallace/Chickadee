### Added

- **Class-goal evaluation engine (achievements Phase 2).** A periodic server-side
  sweep (`evaluateClassGoalAchievements`, lifecycle-registered alongside the
  other monitors) computes, for each assignment carrying a `classGoal`
  achievement, how much of the enrolled class has reached the goal's threshold,
  and upserts a snapshot per (assignment, goal) into a new `achievement_results`
  table. It reads worker-authoritative results over the canonical
  enrolled-student roster, and locks — then freezes — each snapshot once the
  deadline passes. Not yet surfaced: the student progress bar and the positive
  grade bonus that read these snapshots land in Phase 3.
