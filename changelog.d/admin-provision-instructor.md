### Added

- **Admins can set up a course for an instructor who has not logged in.** The admin new-course form takes an optional instructor username, and the admin course page has an "Add staff" form. A person with no account gets a placeholder that their first SSO login adopts, so they arrive as the course's instructor or TA. The instructor roster's staff form and both admin forms share one path. See `docs/multi-course-roles.md`.

### Fixed

- **A staff invite by email no longer makes an account that SSO never adopts.** SSO adopts a placeholder by username, so a placeholder named by an email address left the role on an orphan account. An email address now finds only an existing account; otherwise the form asks for the username. A new placeholder is now audited as `user.provisioned`.
