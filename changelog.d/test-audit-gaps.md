### Security

- **A student can no longer join a closed course from the account page.** `POST /account/enroll` accepted any course that was not archived. It now accepts an open course only, the same rule as `/enroll`. A closed course is instructor-managed.
- **A very large `offset` no longer stops the server.** `GET /api/v1/submissions?offset=` added the offset to the page size without an overflow check, so an offset near the integer limit trapped the process. The end of the page now saturates, and such a request returns an empty page.

### Added

- **Tests for paths that had none.** The branches of a BrightSpace grade removal that keep a grade in LEARN, the override helpers that queue and cancel a removal, the class-activity window on each submission door, the admin BrightSpace credential and test-alert routes, the MCP account enroll and unenroll routes, the GitHub course unbind, the account join, pagination and tier-slice limits, and the idle-logout page script.
- **The browser half of the script-dispatch contract.** The vendored wasm and the browser router are tested against `Tests/Fixtures/script-dispatch-cases.json` again, beside the native worker.
- **A stricter wasm output contract.** The browser test of `Tests/Fixtures/output-contract.json` now requires `score`, `metric` and `composite` on every outcome. Before, it checked each one only when the vendored wasm returned it, so a stale artifact passed. The three wasm tests share one loader in `Tests/BrowserRunnerJSTests/support/`.
- **A warning when the vendored wasm is older than the tree.** The browser test job says so on the run when a PR changes a wasm input, because its contract tests then ran against the previous build.
