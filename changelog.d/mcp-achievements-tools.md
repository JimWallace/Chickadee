### Added

- **MCP achievements authoring.** The content-authoring MCP server gained
  `get_achievements` and `update_achievements`, closing the gap where an agent
  could author tests, solutions, and personalization but not an assignment's
  composable awards. The pair mirrors the web Achievements editor
  (`GET`/`PUT /instructor/:id/achievements`) and runs the same validation via a
  new shared `AchievementsEditing` service. Achievements are server-evaluated
  and display-only, so — unlike every other content edit — updating them does
  not re-validate, re-grade submissions, or close the assignment.
