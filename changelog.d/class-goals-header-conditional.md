### Fixed

- **Submission page no longer shows an empty "Class goals" heading.** The
  class-goals section on the student submission view is now gated on an explicit
  Swift-computed `hasClassGoals` flag rather than `!classGoals.isEmpty` in Leaf,
  so an assignment with no class-goal achievements never renders a bare "Class
  goals" heading with no goals beneath it.
