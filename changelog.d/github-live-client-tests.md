### Added

- **Tests for the live GitHub clients.** A scripted client stands in for GitHub, so the real request builders of `GitHubRepoClient.live` and `GitHubOAuthClient.live` now run in tests: their URLs and path escaping, their headers and bodies, and how each status maps to a result or an error. Fixture tests feed GitHub's documented user, commit and push payloads and check that only the user ID and login, the commit SHA and message, and a push's head commit are kept. A commit status in course-repository mode is now tested to use the organization's token (#1775).
