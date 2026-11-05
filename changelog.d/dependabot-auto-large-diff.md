### Fixed

- **Dependabot auto-merge handles large pull requests.** The `plan` job listed a pull request's files with `gh pr diff`, which GitHub refuses past 300 changed files, so a regenerated JupyterLite bump could never auto-merge. It now reads the paginated files API (#2871).
