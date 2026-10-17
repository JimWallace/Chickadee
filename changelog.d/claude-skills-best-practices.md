### Changed

- **Claude Code skills follow the skill authoring rules.** The `steward` skill
  no longer repeats `CLAUDE.md`, starts with a checklist for each PR wake, and
  names the admin MCP tools by their full names. Three new skills link the
  existing runbooks: `adding-a-language`, `upgrading-swift-toolchain` and
  `cutting-a-minor-release`. Each skill has three evaluation scenarios in
  `.claude/skill-evals/`, and `scripts/check-claude-skills.sh` checks the
  frontmatter, the body length, the links and the scenarios in `format-lint`.
