### Added

- **GitHub commit statuses, opt-in (slice 6 of docs/github-submissions.md).** When the admin ticks *Post commit statuses* while creating the GitHub App, and an instructor ticks *Post commit status* in an assignment's GitHub setting, a graded GitHub submission posts one status on its commit: "n/m public tests passed", with a link to the results page. Release and secret tests are never counted and the grade is never sent. A status is posted only to a private repository, and a failure to post never affects grading. Nothing changes for an assignment that does not opt in.
