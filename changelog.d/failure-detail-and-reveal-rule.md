### Fixed

- **Failure detail applies to the results API and the data export.** A student
  reading `GET /api/v1/submissions/:id/results` or their personal data export
  now sees each failing test at the instructor's `failureDetail` level, as on
  the results page. Before, both returned the full text, including the expected
  value, for an entry set to `actualOnly` or `verdictOnly`. Staff still read
  everything. The setting is part of the API's ETag, so relaxing it re-serves
  past results (#2662).

### Changed

- **One body for the solution-reveal rule.** The dashboard's "View solution"
  action and the solution-serving routes now resolve through the same pure
  function, so the next change to the rule cannot reach only one of them
  (#2665).
