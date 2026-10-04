### Fixed

- **A CI-tolerant time budget for the concurrent evaluator test.** `EvaluatorSpawnGateTests.concurrentEvaluationsAllComplete` starts six `python3` evaluations at once. On a loaded CI runner one of them missed the 5-second default and the test failed (`PersonalizationEvaluatorTests.swift:242`, on #2059 and #2006). The test now passes a 30-second budget to each evaluation. The default the server uses does not change.
