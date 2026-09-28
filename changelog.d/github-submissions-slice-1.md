### Added

- **GitHub App registration (GitHub submissions, slice 1).** Admins can create Chickadee's GitHub App from Integrations → GitHub with GitHub's manifest flow. GitHub returns the App's credentials to the server directly: the identifiers go in a new `github_apps` table and the secrets in `.github-app-secrets` (mode 0600), so no environment variable is needed. Nothing uses the App yet, and no deployment should register one until the privacy review in `docs/github-submissions.md` is complete.
