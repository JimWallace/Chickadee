### Added

- **Notes on Dependabot pull requests.** Every Monday afternoon (UTC), `dependabot-notes.yml` has a small model read each open Dependabot PR (its release notes, its diff and the comments in `.github/dependabot.yml`) and post one comment: upstream breaking changes, where the package is used, and the checks a merge needs. It runs on a schedule, so it uses the normal Actions secret and needs no Dependabot secret. It never approves, merges or blocks.
