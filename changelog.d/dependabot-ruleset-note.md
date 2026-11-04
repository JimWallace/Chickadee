### Changed

- **Why Dependabot went quiet.** `.github/dependabot.yml` now records that the
  repository's `Default` branch ruleset, which has required `editor-smoke-gate`
  on every branch since 21 June 2026, refuses Dependabot's branches, so no
  Dependabot PR has opened since then. The ruleset needs
  `refs/heads/dependabot/**` in its excluded refs. That is a repository setting.
