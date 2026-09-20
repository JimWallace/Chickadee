### Added

- **The `ui-review` agent is checked in and runs in CI.** Its brief lives at
  `.claude/agents/ui-review.md`, so every Claude Code session can run it
  instead of reporting it unavailable, and `.github/workflows/ui-review.yml`
  runs the same brief on every pull request that touches `Resources/Views/`,
  `Public/styles.css` or a page-wiring `Public/*.js`. The workflow posts the
  report on the PR, fails the job on a `changes requested` verdict, and passes
  with a warning when the review cannot run, so an outage never blocks a
  merge. It needs one repository secret, `ANTHROPIC_API_KEY` or
  `CLAUDE_CODE_OAUTH_TOKEN`.
