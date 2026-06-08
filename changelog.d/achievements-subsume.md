### Changed

- **Folded the legacy awards into the unified Achievement model.** The
  previously-hardcoded badges — the per-submission Ace / Rally / Tenacious /
  Swift and the Pathfinder / Trailblazer / Fastest / Minimalist class records —
  are now defined as `Achievement` instances in one registry
  (`BuiltInAchievements`), and the display badge is derived from the model
  (`AchievementBadge(from:)`, shared with the authored individual badges). New
  `comeback` / `persistence` / `speedRun` achievement kinds give the three
  per-submission badges a model home alongside `firstTryPerfect`. Behaviour is
  unchanged — the award conditions and the class-record award logic are
  identical; only the source of each award's identity moved into the model, so
  there is now exactly one place that defines what "Ace" or "Trailblazer" is.
