### Added

- **MCP: pin a test to a notebook cell.** `update_suite` takes `anchor` on a script edit, and `get_suite` reports each script's pin. The web pin route and the tool share `SuiteAnchorPinning`. A call that only sets pins does not close, re-grade or re-validate the assignment, as the web route does not.
- **MCP: prepare a class composite's reference renders.** `set_activity` takes `prepareReference: true`, which queues one reference render per slot through the service behind the edit page's "Prepare reference" button, and reports `referenceJobsQueued`.
- **MCP: `get_assignment` reports the GitHub submission setting** (`enabled`, `statusChecks`, `starterRepository`), read-only. Turning it on sends students' code to GitHub, so it stays an instructor's choice on the edit page.
