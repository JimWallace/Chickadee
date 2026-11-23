### Changed

- **The weekly performance procedure matches the steward rules.** Fix branches start with `steward/`, so a fix may extend an existing test suite. A merge uses `gh pr merge N --auto --squash`, the form the unattended run may use. While a minor release is pending, a merged fix reaches only the dev server, and the run records that instead of waiting 45 minutes for a production deploy.
