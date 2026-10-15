### Added

- **Notes on Dependabot pull requests.** `dependabot-notes.yml` has a small model read each Dependabot PR (its release notes, its diff and the comments in `.github/dependabot.yml`) and post one comment: upstream breaking changes, where the package is used, and the checks a merge needs. It needs the API secret in the Dependabot secret store too. It never approves, merges or blocks.
