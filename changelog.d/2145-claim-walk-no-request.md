### Changed

- **The claim walk takes no `Request` (#2145).** `ClaimEvaluator` now carries the database, the application and the logger beside the two collaborators it already bundled, and `evaluateAndClaimCandidate` reads them from there. The route builds the evaluator from its request; `ClaimWalkTests` builds it from the test app and no longer makes a request. No behaviour change.
