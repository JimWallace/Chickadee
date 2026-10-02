### Fixed

- **A missing or corrupt GitHub App secrets file is reported, not read as "no App".** Five callers loaded the file beside the row with `try?`, so a lost file left the admin page saying registered, students seeing GitHub submission as unavailable, and GitHub seeing 404 on every delivery, with no log line. `GitHubAppRegistration` reads the row and the file together, logs the problem, and the admin page names the file (#1771).
