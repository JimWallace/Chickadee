### Added

- **Broadened browser/worker parity tests.** The shared output-interpretation
  corpus (`Tests/Fixtures/output-contract.json`) gained cases for partial-credit
  `score`, JSON footers trailed by blank lines, and footer-stripping on the pass
  path. The dependency-skip result wording is now pinned by a shared fixture
  (`Tests/Fixtures/dependency-skip-message.json`): both producers (the worker's
  new `skippedPrerequisiteMessage` Core helper and `Public/browser-runner.js`)
  and the server-side `parseSkip` parser assert against it, so the string can no
  longer drift between the two runners or their consumers.
