### Changed

- **Shared fixtures for the API tests (#2717, part 1).** The per-group activity suites use one `PerGroupActivityFixture` and one `joinSession`. Outcomes that a test does not inspect come from `TestOutcome.stub`. The GitHub suites share one App key through `GitHubTestApp`; a key that does not generate now fails at once with its own error. A new `TestScenario` builder in `Fixtures.swift` makes a course, a setup and an assignment, and the Groups and Personalization folders use it. No test changes what it asserts.
