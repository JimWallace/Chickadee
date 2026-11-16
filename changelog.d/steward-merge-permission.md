### Changed

- **The nightly steward can merge again without a person.** In auto mode the broad `Bash` allow rule does not apply, and the safety check refused `gh pr merge` on 2026-11-15. The project settings now allow `gh pr merge` and `gh label create` by name, and deny `gh pr merge` with `--admin`.
