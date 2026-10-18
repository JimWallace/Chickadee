### Added

- **Interaction review on pull requests.** A new `interaction-review` agent checks a change for side effects on other features. It uses a new map of the shared objects that several features read or write (`docs/feature-interactions.md`). CI runs it on each pull request that changes code. Its verdict is advisory while its precision is measured.
