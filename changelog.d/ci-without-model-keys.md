### Removed

- **The CI agent workflows.** They needed an Anthropic API key or a subscription token, and the repository's token stopped working on 2026-10-20. Every agent then failed before the model ran, and the checks stayed green, so the PR reviews, the weekly digest and the docs audit stopped without anyone seeing it. The UI review, interaction review, UI audit, docs audit, CI triage, visual-diff explainer, mutation pretriage and Dependabot notes workflows are gone, with the shared agent action and its guard. The review and audit agents still run in Claude Code sessions, and CLAUDE.md now says that a session is their only route.

### Changed

- **The weekly digest needs no model.** A script with a self-test writes it from the same reports, by stated rules. It reads whether the ZAP scan ran from the newest run, not from the ZAP issue's date: the scan edits that issue only when its findings change, so the 2026-10-19 digest reported a missing scan in a week when the scan ran and passed. It flags a kernel update with a major version bump, where the model used to read upstream release notes.
