### Added

- **A monthly documentation audit.** `docs-audit.yml` runs the new `docs-audit` agent (the sonnet family), which checks every `CLAUDE.md` file and a rotating quarter of `docs/` against the repository: paths, workflows, scripts and agents that no longer exist, counts that changed, processes that no longer run, and docs the reference list does not name. It files one issue that replaces the previous one. It is a report, never a gate.
